#if ENABLE_RDP_2
import AppKit
import ImageIO
import UniformTypeIdentifiers
import JTSCompanionClient
import Testing
@testable import JTSTerminal

@MainActor struct CompanionDesktopSnapshotTests {
    @Test func videoToolboxDecodesAnOrderedIDRAndDependentFrame() throws {
        // Self-generated 64x64 red, baseline H.264; SEI stripped. The second
        // access unit is a P frame and therefore requires the first unit.
        let accessUnits = [
            "AAAAAQkQAAAAAWdCwAraEJsBEAAAAwAQAAADAEjxImoAAAABaM4PyAAAAWWIhDoRigACGPHAAED2OAAIeUnJyddddddddddddeA=",
            "AAAAAQkwAAABQZogF6CM"
        ]
        let decoder = CompanionDesktopFrameDecoder(), generation = UUID()
        for bytes in accessUnits {
            let observation = try CompanionDesktopObservation(CompanionDesktopEnvelope(kind: "frame", id: nil, operation: nil,
                generation: generation, sessionId: 1, body: ["frameID": .string(UUID().uuidString),
                    "observationID": .string(UUID().uuidString), "width": .integer(64), "height": .integer(64),
                    "codec": .string("h264"), "capturedAt": .string(ISO8601DateFormatter().string(from: Date()))],
                payloadBase64: bytes))
            let image = try decoder.decode(observation)
            #expect(image.width == 64 && image.height == 64)
            let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 32, y: 32)?.usingColorSpace(.deviceRGB))
            #expect(color.redComponent > 0.8 && color.blueComponent < 0.2)
        }
    }
    @Test func retainedObservationScreenshotCannotBecomeTheNewViewportFrame() throws {
        let retained = try frame(red: 1, blue: 0), latest = try frame(red: 0, blue: 1)
        let viewport = CompanionDesktopFrameDecoder()
        _ = try viewport.decode(retained)
        _ = try viewport.decode(latest)
        let result = try CompanionDesktopFrameDecoder.snapshotPNG(retained)
        let source = try #require(CGImageSourceCreateWithData(result as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bitmap = NSBitmapImageRep(cgImage: image)
        let color = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        #expect(color.redComponent > 0.8 && color.blueComponent < 0.2)
        #expect(retained.frameID != latest.frameID)
    }
    @Test func mismatchedSnapshotDimensionsAreRejected() throws {
        let original = try frame(red: 1, blue: 0)
        let envelope = CompanionDesktopEnvelope(kind: "frame", id: nil, operation: "observe",
            generation: original.generation, sessionId: original.sessionID,
            body: ["frameID": .string(original.frameID.uuidString), "observationID": .string(original.observationID.uuidString),
                "width": .integer(4), "height": .integer(2), "codec": .string("jpeg"),
                "capturedAt": .string(ISO8601DateFormatter().string(from: Date()))], payloadBase64: original.bytes.base64EncodedString())
        let wrong = try CompanionDesktopObservation(envelope)
        #expect(throws: CompanionDesktopError.invalidFrame) { try CompanionDesktopFrameDecoder.snapshotPNG(wrong) }
    }
    private func frame(red: CGFloat, blue: CGFloat) throws -> CompanionDesktopObservation {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage()), bytes = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        try #require(CGImageDestinationFinalize(output))
        return try CompanionDesktopObservation(CompanionDesktopEnvelope(kind: "frame", id: nil, operation: "observe",
            generation: UUID(), sessionId: 1, body: ["frameID": .string(UUID().uuidString),
                "observationID": .string(UUID().uuidString), "width": .integer(2), "height": .integer(2),
                "codec": .string("jpeg"), "capturedAt": .string(ISO8601DateFormatter().string(from: Date()))],
            payloadBase64: (bytes as Data).base64EncodedString()))
    }
}
#endif
