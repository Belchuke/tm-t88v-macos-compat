import Foundation

public enum RasterReceipt {
    public static func build(bitmap: MonoBitmap, model: PrinterModel, feedLines: Int = 3) throws -> Data {
        guard bitmap.width <= model.dotsPerLine else {
            throw RasterError.bitmapWiderThanPrinter(width: bitmap.width, maxWidth: model.dotsPerLine)
        }
        let encoder = EscPosEncoder()
        encoder.initialize().align(.left)
        encoder.raw([UInt8](RasterEncoder.encode(bitmap)))
        encoder.feed(lines: feedLines)
        encoder.cut(model.cutMode, feedUnits: model.cutFeedUnits)
        return encoder.data
    }
}
