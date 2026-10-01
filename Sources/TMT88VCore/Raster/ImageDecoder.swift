import CoreGraphics
import Foundation
import ImageIO

public enum ImageDecoder {
    public static func load(url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RasterError.unreadableImage("cannot open \(url.path)")
        }
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw RasterError.unreadableImage("\(url.lastPathComponent) is not a decodable image")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw RasterError.unreadableImage("decoding \(url.lastPathComponent) failed")
        }
        return image
    }
}
