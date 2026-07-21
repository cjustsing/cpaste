import CoreGraphics
import Foundation
import ImageIO

public enum ImageThumbnailDecoder {
    public static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0 else {
            return nil
        }

        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary

        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }
}
