import CoreGraphics
import Foundation

public enum ScaleMode: String, Sendable {
    case fit
    case actualSize = "actual-size"
}

public struct RasterOptions: Sendable {
    public var dither: DitherMode = .floydSteinberg
    public var scale: ScaleMode = .fit
    public var threshold: UInt8 = 128
    public var maxHeight = 32_768

    public init() {}
}

public enum RasterProcessor {
    public static func targetSize(
        sourceWidth: Int,
        sourceHeight: Int,
        maxWidth: Int,
        mode: ScaleMode
    ) throws -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0, maxWidth > 0 else {
            throw RasterError.invalidDimensions(width: sourceWidth, height: sourceHeight)
        }
        if sourceWidth <= maxWidth { return (sourceWidth, sourceHeight) }
        if mode == .actualSize { throw RasterError.imageTooWide(width: sourceWidth, maxWidth: maxWidth) }
        let height = max(1, Int((Double(sourceHeight) * Double(maxWidth) / Double(sourceWidth)).rounded()))
        return (maxWidth, height)
    }

    public static func process(_ image: CGImage, model: PrinterModel, options: RasterOptions = RasterOptions()) throws -> MonoBitmap {
        let gray = try renderGray(image, canvasWidth: model.dotsPerLine, options: options)
        return Dithering.apply(gray, mode: options.dither, threshold: options.threshold)
    }

    public static func process(gray: GrayImage, model: PrinterModel, options: RasterOptions = RasterOptions()) throws -> MonoBitmap {
        let size = try targetSize(sourceWidth: gray.width, sourceHeight: gray.height, maxWidth: model.dotsPerLine, mode: options.scale)
        guard size.height <= options.maxHeight else {
            throw RasterError.imageTooTall(height: size.height, maxHeight: options.maxHeight)
        }
        guard gray.width <= model.dotsPerLine else {
            guard let image = cgImage(gray) else { throw RasterError.contextCreationFailed }
            return try process(image, model: model, options: options)
        }
        var canvas = GrayImage(width: model.dotsPerLine, height: gray.height)
        let offset = (model.dotsPerLine - gray.width) / 2
        for y in 0..<gray.height {
            canvas.pixels.replaceSubrange(
                (y * canvas.width + offset)..<(y * canvas.width + offset + gray.width),
                with: gray.pixels[(y * gray.width)..<((y + 1) * gray.width)]
            )
        }
        return Dithering.apply(canvas, mode: options.dither, threshold: options.threshold)
    }

    public static func cgImage(_ gray: GrayImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(gray.pixels) as CFData) else { return nil }
        return CGImage(
            width: gray.width, height: gray.height,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: gray.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    public static func renderGray(_ image: CGImage, canvasWidth: Int, options: RasterOptions = RasterOptions()) throws -> GrayImage {
        let size = try targetSize(sourceWidth: image.width, sourceHeight: image.height, maxWidth: canvasWidth, mode: options.scale)
        guard size.height <= options.maxHeight else {
            throw RasterError.imageTooTall(height: size.height, maxHeight: options.maxHeight)
        }

        var pixels = [UInt8](repeating: 255, count: canvasWidth * size.height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: canvasWidth,
                height: size.height,
                bitsPerComponent: 8,
                bytesPerRow: canvasWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            let offset = (canvasWidth - size.width) / 2
            context.draw(image, in: CGRect(x: offset, y: 0, width: size.width, height: size.height))
            return true
        }
        guard drawn else { throw RasterError.contextCreationFailed }
        return GrayImage(width: canvasWidth, height: size.height, pixels: pixels)
    }

    public static func previewImage(_ bitmap: MonoBitmap) -> CGImage? {
        var gray = [UInt8](repeating: 255, count: bitmap.width * bitmap.height)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap.isBlack(x: x, y: y) {
                gray[y * bitmap.width + x] = 0
            }
        }
        guard let provider = CGDataProvider(data: Data(gray) as CFData) else { return nil }
        return CGImage(
            width: bitmap.width, height: bitmap.height,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bitmap.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
