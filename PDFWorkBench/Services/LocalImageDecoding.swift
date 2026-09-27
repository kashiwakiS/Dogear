import CoreGraphics
import Foundation
import ImageIO

/// Bounded, orientation-aware local previews shared by macOS and iPadOS.
/// Only file URLs are accepted; viewing an attachment never loads a remote URL.
nonisolated enum LocalImageDecoding {
    static func stillImage(at url: URL, maximumPixelSize: Int = 2_048) -> CGImage? {
        guard url.isFileURL, maximumPixelSize > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary)
    }
}
