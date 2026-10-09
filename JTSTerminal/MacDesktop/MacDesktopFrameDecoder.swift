#if ENABLE_RDP_2
import CoreGraphics
import Foundation
import ImageIO
import RemoteDesktopCore

nonisolated struct MacDesktopDecodedFrame: @unchecked Sendable {
    let image: CGImage
    let width: Int
    let height: Int
}

nonisolated enum MacDesktopFrameDecoder {
    // At most 64 MB of decoded pixels, independent of the compressed packet size.
    nonisolated static let maximumPixelCount = 16_000_000

    nonisolated static func decode(_ frame: RemoteDesktopCore.DesktopFrame) throws -> MacDesktopDecodedFrame {
        guard let source = CGImageSourceCreateWithData(frame.jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == frame.width, height == frame.height,
              width > 0, height > 0,
              width <= DesktopProtocol.maximumDimension, height <= DesktopProtocol.maximumDimension,
              width <= maximumPixelCount / height else {
            throw MacDesktopFrameError.invalidDimensions
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw MacDesktopFrameError.invalidJPEG
        }
        return MacDesktopDecodedFrame(image: image, width: width, height: height)
    }
}

nonisolated enum MacDesktopFrameError: LocalizedError {
    case invalidDimensions, invalidJPEG
    nonisolated var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return AppLanguage.localizedForStoredLanguage(
                "The other Mac sent an invalid frame size or one larger than this client supports.",
                "对方 Mac 的画面尺寸无效或超过客户端限制。"
            )
        case .invalidJPEG:
            return AppLanguage.localizedForStoredLanguage(
                "The other Mac's desktop image could not be decoded.",
                "无法解码对方 Mac 的桌面画面。"
            )
        }
    }
}

#endif
