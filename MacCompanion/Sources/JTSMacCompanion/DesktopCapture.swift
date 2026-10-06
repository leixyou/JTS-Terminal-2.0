import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import RemoteDesktopCore
import ScreenCaptureKit

enum DesktopCaptureError: LocalizedError {
    case permissionRequired
    case displayUnavailable
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "请先在系统设置中允许 JTS Mac Companion 录制屏幕。"
        case .displayUnavailable: return "没有找到可共享的主显示器。请确认这台 Mac 已登录桌面。"
        case .cancelled: return "桌面共享启动已取消。"
        }
    }
}

/// Captures the logged-in user's primary display. Permission requests belong to
/// the visible host UI; starting a network session never requests them silently.
@MainActor
final class DesktopCapture {
    var onFrame: ((DesktopFrame) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var displayBounds = CGDisplayBounds(CGMainDisplayID())

    private var stream: SCStream?
    private var output: DesktopStreamOutput?
    private var generation = UUID()
    private var isStarting = false

    func start() async throws {
        guard stream == nil, !isStarting else { return }
        guard CGPreflightScreenCaptureAccess() else {
            throw DesktopCaptureError.permissionRequired
        }
        isStarting = true
        let currentGeneration = UUID()
        generation = currentGeneration
        defer {
            if generation == currentGeneration { isStarting = false }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard generation == currentGeneration else { throw DesktopCaptureError.cancelled }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw DesktopCaptureError.displayUnavailable
        }
        displayBounds = CGDisplayBounds(display.displayID)
        let pixelWidth = max(1, CGDisplayPixelsWide(display.displayID))
        let pixelHeight = max(1, CGDisplayPixelsHigh(display.displayID))
        let scale = min(1, 1920.0 / Double(pixelWidth))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(Double(pixelWidth) * scale))
        configuration.height = max(1, Int(Double(pixelHeight) * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let output = DesktopStreamOutput(
            onFrame: { [weak self] frame in
                guard let self, self.generation == currentGeneration else { return }
                self.onFrame?(frame)
            },
            onFailure: { [weak self] message in
                guard let self, self.generation == currentGeneration else { return }
                self.onFailure?(message)
            }
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        self.output = output
        self.stream = stream
        do {
            try await stream.startCapture()
            guard generation == currentGeneration else {
                try? await stream.stopCapture()
                throw DesktopCaptureError.cancelled
            }
        } catch {
            output.invalidate()
            if generation == currentGeneration {
                self.output = nil
                self.stream = nil
            }
            throw error
        }
    }

    func stop() async {
        generation = UUID()
        isStarting = false
        output?.invalidate()
        let activeStream = stream
        stream = nil
        output = nil
        try? await activeStream?.stopCapture()
    }
}

/// Encoding stays off the UI thread. A single replaceable pending frame prevents
/// a busy main queue or slow network consumer from accumulating screenshots.
private final class DesktopStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "com.jts.mac-companion.screen-encoder", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    private var isActive = true
    private var deliveryScheduled = false
    private var pendingFrame: DesktopFrame?
    private let onFrame: @MainActor (DesktopFrame) -> Void
    private let onFailure: @MainActor (String) -> Void

    init(onFrame: @escaping @MainActor (DesktopFrame) -> Void,
         onFailure: @escaping @MainActor (String) -> Void) {
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func invalidate() {
        lock.lock()
        isActive = false
        pendingFrame = nil
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        lock.lock()
        let active = isActive
        lock.unlock()
        guard active else { return }

        autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace,
                                                       options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.72]),
                  jpeg.count <= 8 * 1024 * 1024 else { return }
            let frame = DesktopFrame(width: CVPixelBufferGetWidth(pixelBuffer),
                                     height: CVPixelBufferGetHeight(pixelBuffer), jpeg: jpeg)
            enqueue(frame)
        }
    }

    private func enqueue(_ frame: DesktopFrame) {
        lock.lock()
        guard isActive else { lock.unlock(); return }
        pendingFrame = frame
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        if shouldSchedule {
            Task { @MainActor [weak self] in self?.deliverLatestFrame() }
        }
    }

    @MainActor
    private func deliverLatestFrame() {
        lock.lock()
        let frame = isActive ? pendingFrame : nil
        pendingFrame = nil
        deliveryScheduled = false
        lock.unlock()
        if let frame { onFrame(frame) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let active = isActive
        lock.unlock()
        guard active else { return }
        invalidate()
        Task { @MainActor [weak self] in self?.onFailure(error.localizedDescription) }
    }
}
