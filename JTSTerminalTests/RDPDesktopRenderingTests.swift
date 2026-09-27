#if ENABLE_RDP_2
import AppKit
import SwiftUI
import Testing
@testable import JTSTerminal

@MainActor
@Suite(.serialized)
struct RDPDesktopRenderingTests {
    @Test func minimumConnectedWindowKeepsTheToolbarCompactAndTheDesktopVisible() throws {
        _ = NSApplication.shared
        let target = RemoteSession(name: "Narrow desktop", host: "narrow.test", username: "operator", connectionType: .rdp)
        let state = RDPDesktopSessionState(
            sessionID: UUID(), targetID: target.targetID, phase: .connected, runtimeAvailability: .available,
            companion: WindowsCompanionState(availability: .missing, protocolVersion: nil, companionVersion: nil, reason: nil),
            stateRevision: 1, latestFrameID: UUID(), remotePixelWidth: 1_496, remotePixelHeight: 868,
            connectedAt: Date(), reconnectAttempt: nil, reconnectMaximumAttempts: nil,
            reconnectScheduledAt: nil, lastErrorCode: nil, lastErrorMessage: nil)
        let source = try quadrantImage()
        let root = RDPDesktopWindowSurface(target: target,
            presentation: RDPDesktopWorkspacePresentation(state: state, frameImage: source,
                disconnect: {}, performManualAction: { _ in }),
            openServerProperties: {}, toggleFullScreen: {})
            .environment(\.appLanguage, .english)
        let controller = RDPDesktopWindowCoordinator.hostingController(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // The coordinator's minimum is a window-frame size, including titlebar.
        // Exercise that smaller real content area rather than a 640x480 canvas.
        window.setFrame(CGRect(x: 0, y: 0, width: 640, height: 480), display: false)
        defer { window.orderOut(nil); window.close() }
        for _ in 0..<20 {
            controller.view.layoutSubtreeIfNeeded()
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        let toolbar = try #require(descendant(controller.view, id: "rdp-desktop-control-bar-layout"))
        let viewport = try #require(descendant(controller.view, id: RDPDesktopLayoutIdentifiers.viewportHost))
        let toolbarRect = toolbar.convert(toolbar.bounds, to: controller.view)
        let viewportRect = viewport.convert(viewport.bounds, to: controller.view)
        print("RDP_NARROW window=\(window.frame) content=\(controller.view.bounds) toolbar=\(toolbarRect) viewport=\(viewportRect)")
        #expect(window.frame.size == CGSize(width: 640, height: 480))
        #expect(toolbarRect.height > 0 && toolbarRect.height <= 110)
        #expect(viewportRect.height >= controller.view.bounds.height * (2.0 / 3.0))
        #expect(controller.view.bounds.insetBy(dx: -1, dy: -1).contains(viewportRect))
        #expect(controller.view.bounds.insetBy(dx: -1, dy: -1).contains(toolbarRect))
    }

    @Test func aSettledViewportOrDisabledPolicyCancelsTheOlderTallResize() async throws {
        let coordinator = RDPDesktopResizeCoordinator(debounce: .milliseconds(20))
        let remote = CGSize(width: 1_496, height: 868)
        var sent: [CGSize] = []
        func schedule(_ size: CGSize, enabled: Bool = true) {
            coordinator.schedule(viewport: size, remote: remote, enabled: enabled, sessionID: UUID(),
                isStillAllowed: { true }, send: { sent.append(CGSize(width: $0, height: $1)) })
        }
        schedule(CGSize(width: 1_496, height: 2_317))
        schedule(remote) // No network work is needed, but the old request must go.
        try await Task.sleep(for: .milliseconds(60))
        #expect(sent.isEmpty)
        schedule(CGSize(width: 1_496, height: 2_317))
        schedule(CGSize(width: 1_200, height: 800), enabled: false)
        try await Task.sleep(for: .milliseconds(60))
        #expect(sent.isEmpty)
        schedule(CGSize(width: 1_100, height: 700))
        schedule(CGSize(width: 1_200, height: 800))
        try await Task.sleep(for: .milliseconds(60))
        #expect(sent == [CGSize(width: 1_200, height: 800)])
    }

    @Test func resizingRechecksAuthorityAndRejectsTransientZeroOrInvalidViewports() async throws {
        let coordinator = RDPDesktopResizeCoordinator(debounce: .milliseconds(20))
        var allowed = true
        var sent = 0
        func schedule(_ size: CGSize) {
            coordinator.schedule(viewport: size, remote: .zero, enabled: true, sessionID: UUID(),
                isStillAllowed: { allowed }, send: { _, _ in sent += 1 })
        }
        schedule(CGSize(width: 1_200, height: 800))
        allowed = false
        try await Task.sleep(for: .milliseconds(60))
        #expect(sent == 0)
        allowed = true
        schedule(CGSize(width: 1_200, height: 800))
        coordinator.cancel() // Disconnect, reattachment, or a different session.
        try await Task.sleep(for: .milliseconds(60))
        #expect(sent == 0)
        for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 800), CGSize(width: 800, height: -1)] {
            schedule(size)
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(sent == 0)
    }

    @Test func oversizedRestoredWindowsFitTheCurrentDisplayWithoutMovingValidWindows() {
        let screen = CGRect(x: -1_600, y: 24, width: 1_600, height: 976)
        #expect(RDPDesktopWindowCoordinator.frameWithinVisibleScreen(
            CGRect(x: -1_600, y: -1_400, width: 1_512, height: 2_398), visible: screen)
                == CGRect(x: -1_600, y: 24, width: 1_512, height: 976))
        let valid = CGRect(x: -1_400, y: 100, width: 1_120, height: 760)
        #expect(RDPDesktopWindowCoordinator.frameWithinVisibleScreen(valid, visible: screen) == valid)
    }

    @Test func independentHostShowsTheWholeDesktopAndMapsClicksAcrossWindowAndFullScreenSizes() throws {
        _ = NSApplication.shared
        let target = RemoteSession(name: "Viewport", host: "viewport.test", username: "tester", connectionType: .rdp)
        let state = RDPDesktopSessionState(
            sessionID: UUID(), targetID: target.targetID, phase: .connected, runtimeAvailability: .available,
            companion: WindowsCompanionState(availability: .ready, protocolVersion: 1, companionVersion: "test", reason: nil),
            stateRevision: 1, latestFrameID: UUID(), remotePixelWidth: 1_496, remotePixelHeight: 868,
            connectedAt: Date(), reconnectAttempt: nil, reconnectMaximumAttempts: nil,
            reconnectScheduledAt: nil, lastErrorCode: nil, lastErrorMessage: nil)
        let source = try quadrantImage()
        var actions: [DesktopActionRequest] = []
        let root = RDPDesktopWindowSurface(target: target,
            presentation: RDPDesktopWorkspacePresentation(state: state, frameImage: source,
                performManualAction: { actions.append($0) }),
            openServerProperties: {}, toggleFullScreen: {})
            .environment(\.appLanguage, .english)
        let controller = RDPDesktopWindowCoordinator.hostingController(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_120, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.orderOut(nil); window.close() }

        // This exercises the production NSHostingController and a full-screen
        // content proposal without moving the test runner into another Space.
        for size in [CGSize(width: 1_120, height: 760), CGSize(width: 1_512, height: 982),
                     CGSize(width: 840, height: 600), CGSize(width: 1_512, height: 982)] {
            window.setContentSize(size)
            for _ in 0..<20 {
                controller.view.layoutSubtreeIfNeeded()
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            }
            let view = try #require(descendant(controller.view, id: RDPDesktopLayoutIdentifiers.framebuffer) as? RDPDesktopNSView)
            let viewport = try #require(descendant(controller.view, id: RDPDesktopLayoutIdentifiers.viewportHost))
            let imageRect = view.convert(view.bounds, to: controller.view)
            let viewportRect = viewport.convert(viewport.bounds, to: controller.view)
            #expect(abs(controller.view.bounds.width - size.width) <= 1)
            #expect(abs(controller.view.bounds.height - size.height) <= 1)
            #expect(viewportRect.insetBy(dx: -1, dy: -1).contains(imageRect))
            #expect(abs(imageRect.midX - viewportRect.midX) <= 1)
            #expect(abs(imageRect.midY - viewportRect.midY) <= 1)
            #expect(abs(view.visibleRect.intersection(view.bounds).width - view.bounds.width) <= 1)
            #expect(abs(view.visibleRect.intersection(view.bounds).height - view.bounds.height) <= 1)
            #expect(abs(imageRect.height - imageRect.width * 868.0 / 1_496.0) <= 1)
            print("RDP_LAYOUT size=\(size) image=\(imageRect) viewport=\(viewportRect) bounds=\(view.bounds) visible=\(view.visibleRect)")
            var ancestor: NSView? = view
            while let item = ancestor {
                print("RDP_ANCESTOR \(type(of: item)) frame=\(item.frame) bounds=\(item.bounds) visible=\(item.visibleRect)")
                ancestor = item.superview
            }

            let raster = try renderFramebuffer(view)
            for sample in samples {
                let (fraction, expectedColor, expectedPoint) = sample
                let color = try #require(raster.colorAt(x: Int(CGFloat(raster.pixelsWide) * fraction.x),
                    y: Int(CGFloat(raster.pixelsHigh) * fraction.y))?.usingColorSpace(.sRGB))
                assertQuadrantColor(color, expected: expectedColor)
                let location = view.convert(CGPoint(x: view.bounds.width * fraction.x,
                    y: view.bounds.height * fraction.y), to: nil)
                let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                view.mouseDown(with: event)
                let point = try #require(actions.last?.point)
                #expect(actions.last?.action == .mouseDown)
                #expect(abs(point.x - expectedPoint.x) <= 1)
                #expect(abs(point.y - expectedPoint.y) <= 1)
                view.mouseUp(with: event)
            }
        }
    }

    @Test func resizingTheFramebufferKeepsAllQuadrantsWithoutAReplacementImage() throws {
        let view = RDPDesktopNSView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let source = try quadrantImage()
        view.image = source
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        for size in [CGSize(width: 640, height: 480), CGSize(width: 1_496, height: 868), CGSize(width: 800, height: 600)] {
            window.setContentSize(size)
            view.layoutSubtreeIfNeeded()
            let raster = try renderFramebuffer(view)
            for sample in samples {
                let fraction = sample.0
                let expected = sample.1
                let color = try #require(raster.colorAt(x: Int(CGFloat(raster.pixelsWide) * fraction.x),
                    y: Int(CGFloat(raster.pixelsHigh) * fraction.y))?.usingColorSpace(.sRGB))
                assertQuadrantColor(color, expected: expected)
            }
        }
    }

    private var samples: [(CGPoint, (CGFloat, CGFloat, CGFloat), DesktopPoint)] {
        [(CGPoint(x: 0.25, y: 0.25), (1, 0, 0), DesktopPoint(x: 374, y: 217)),
         (CGPoint(x: 0.75, y: 0.25), (0, 1, 0), DesktopPoint(x: 1_122, y: 217)),
         (CGPoint(x: 0.25, y: 0.75), (0, 0, 1), DesktopPoint(x: 374, y: 651)),
         (CGPoint(x: 0.75, y: 0.75), (1, 1, 1), DesktopPoint(x: 1_122, y: 651))]
    }

    private func assertQuadrantColor(_ color: NSColor, expected: (CGFloat, CGFloat, CGFloat)) {
        // Check quadrant identity, not display calibration. ColorSync can add a
        // small secondary component even for a tagged source on this host.
        // Every expected channel must remain bright and every other channel
        // dark; black/blank, flipped, cropped or wrong quadrants all fail.
        for (actual, channel) in zip([color.redComponent, color.greenComponent, color.blueComponent],
                                    [expected.0, expected.1, expected.2]) {
            if channel == 1 { #expect(actual > 0.8) }
            else { #expect(actual < 0.35) }
        }
        #expect(color.alphaComponent > 0.95)
    }

    // A fixed sRGB CGContext tests the production draw implementation without
    // cacheDisplay's implicit test-host screen/profile conversions. Ancestor
    // clipping and the native window's size are asserted separately above.
    private func renderFramebuffer(_ view: RDPDesktopNSView) throws -> NSBitmapImageRep {
        let width = Int(view.bounds.width.rounded(.up))
        let height = Int(view.bounds.height.rounded(.up))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / view.bounds.width, y: -CGFloat(height) / view.bounds.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let image = try #require(context.makeImage())
        return NSBitmapImageRep(cgImage: image)
    }

    private func quadrantImage() throws -> NSImage {
        var bytes = Data(count: 40 * 40 * 4)
        for y in 0..<40 { for x in 0..<40 {
            let rgb: (UInt8, UInt8, UInt8) = y < 20 ? (x < 20 ? (255, 0, 0) : (0, 255, 0))
                : (x < 20 ? (0, 0, 255) : (255, 255, 255))
            let offset = (y * 40 + x) * 4
            bytes[offset] = rgb.0; bytes[offset + 1] = rgb.1; bytes[offset + 2] = rgb.2; bytes[offset + 3] = 255
        } }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(width: 40, height: 40, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 160, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return NSImage(cgImage: image, size: NSSize(width: 1_496, height: 868))
    }

    private func descendant(_ view: NSView, id: String) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { descendant($0, id: id) }.first
    }
}
#endif
