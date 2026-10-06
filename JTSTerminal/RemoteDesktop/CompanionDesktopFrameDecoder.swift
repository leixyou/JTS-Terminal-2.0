#if ENABLE_RDP_2
import AppKit
import CoreImage
import ImageIO
import VideoToolbox
import UniformTypeIdentifiers
import JTSCompanionClient

/// Decoder resources are scoped to one Windows session generation.
@MainActor
final class CompanionDesktopFrameDecoder {
    static func snapshotPNG(_ observation: CompanionDesktopObservation) throws -> Data {
        guard observation.codec == "jpeg" else { throw CompanionDesktopError.invalidFrame }
        let image = try CompanionDesktopFrameDecoder().decode(observation)
        let bytes = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw CompanionDesktopError.invalidFrame
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw CompanionDesktopError.invalidFrame }
        return bytes as Data
    }
    private var decompressor: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameters: [Data] = []
    private let images = CIContext(options: [.cacheIntermediates: false])
    func reset() {
        if let decompressor { VTDecompressionSessionInvalidate(decompressor) }
        decompressor = nil; format = nil; parameters = []
    }
    func decode(_ observation: CompanionDesktopObservation) throws -> CGImage {
        if observation.codec == "jpeg" {
            guard let source = CGImageSourceCreateWithData(observation.bytes as CFData, nil),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == observation.width,
                  properties[kCGImagePropertyPixelHeight] as? Int == observation.height,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else {
                throw CompanionDesktopError.invalidFrame
            }
            return image
        }
        let nals = try Self.annexBNALs(observation.bytes)
        let sps = nals.first { $0.first.map { $0 & 31 == 7 } ?? false }
        let pps = nals.first { $0.first.map { $0 & 31 == 8 } ?? false }
        if let sps, let pps, [sps, pps] != parameters {
            reset()
            var next: CMFormatDescription?
            let result = sps.withUnsafeBytes { spsBytes in pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                return pointers.withUnsafeBufferPointer { ptr in
                    let sizes = [sps.count, pps.count]
                    return sizes.withUnsafeBufferPointer { lengths in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                            parameterSetCount: 2, parameterSetPointers: ptr.baseAddress!, parameterSetSizes: lengths.baseAddress!,
                            nalUnitHeaderLength: 4, formatDescriptionOut: &next)
                    }
                }
            } }
            guard result == noErr, let next else { throw CompanionDesktopError.invalidFrame }
            let dimensions = CMVideoFormatDescriptionGetDimensions(next)
            guard dimensions.width == observation.width, dimensions.height == observation.height else { throw CompanionDesktopError.invalidFrame }
            format = next; parameters = [sps, pps]
            guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: next,
                decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil,
                decompressionSessionOut: &decompressor) == noErr else { reset(); throw CompanionDesktopError.invalidFrame }
        }
        guard let format, let decompressor else { throw CompanionDesktopError.invalidFrame }
        var avcc = Data()
        for nal in nals where nal.first.map({ ![7,8,9].contains($0 & 31) }) ?? false {
            var length = UInt32(nal.count).bigEndian
            avcc.append(withUnsafeBytes(of: &length) { Data($0) }); avcc.append(nal)
        }
        guard !avcc.isEmpty else { throw CompanionDesktopError.invalidFrame }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block else { throw CompanionDesktopError.invalidFrame }
        let copy = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard copy == kCMBlockBufferNoErr else { throw CompanionDesktopError.invalidFrame }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { throw CompanionDesktopError.invalidFrame }
        let output = CompanionDecodedPixel()
        let status = VTDecompressionSessionDecodeFrame(decompressor, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, pixel, _, _ in if status == noErr { output.accept(pixel) }
        }
        guard status == noErr else { throw CompanionDesktopError.invalidFrame }
        VTDecompressionSessionWaitForAsynchronousFrames(decompressor)
        guard let pixel = output.pixel, let image = images.createCGImage(CIImage(cvPixelBuffer: pixel),
            from: CGRect(x: 0, y: 0, width: observation.width, height: observation.height)) else { throw CompanionDesktopError.invalidFrame }
        return image
    }

    private static func annexBNALs(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = []; var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 1 { starts.append((i, 3)); i += 3 }
            else if i + 4 <= bytes.count, bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 { starts.append((i, 4)); i += 4 }
            else { i += 1 }
        }
        guard !starts.isEmpty, starts[0].0 == 0, starts.count <= 256 else { throw CompanionDesktopError.invalidFrame }
        return try starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index+1].0 : bytes.count
            guard end > start.0 + start.1 else { throw CompanionDesktopError.invalidFrame }
            return Data(bytes[(start.0 + start.1)..<end])
        }
    }
}

private final class CompanionDecodedPixel: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CVPixelBuffer?
    func accept(_ pixel: CVPixelBuffer?) { lock.lock(); value = pixel; lock.unlock() }
    var pixel: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
