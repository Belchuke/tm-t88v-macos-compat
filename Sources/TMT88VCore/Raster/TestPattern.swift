import CoreGraphics
import CoreText
import Foundation
import ImageIO

public enum TestPattern {
    public static func make(width: Int = 512) -> CGImage? {
        let height = 920
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setStrokeColor(gray: 0, alpha: 1)

        ctx.setShouldAntialias(false)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(width - 1), height: CGFloat(height - 1)))

        var y = 14
        ctx.setShouldAntialias(true)
        text(ctx, "TM-T88V RASTER TEST", size: 30, bold: true, centeredIn: width, baseline: y + 30)
        y += 44
        text(ctx, "\(width) dots wide  |  180 dpi", size: 14, bold: false, centeredIn: width, baseline: y + 14)
        y += 30

        ctx.setShouldAntialias(false)
        label(ctx, "HORIZONTAL LINES 1/2/3/4/6 px", y: &y)
        for thickness in [1, 2, 3, 4, 6] {
            ctx.fill(CGRect(x: 12, y: y, width: width - 24, height: thickness))
            y += thickness + 6
        }
        y += 8

        label(ctx, "VERTICAL LINES gap 1..8 px", y: &y)
        var x = 12
        for gap in 1...8 {
            ctx.fill(CGRect(x: x, y: y, width: 1, height: 50))
            x += gap + 1
            ctx.fill(CGRect(x: x, y: y, width: 2, height: 50))
            x += gap + 2
        }
        let verticalEnd = x
        for index in 0..<((width - 24 - verticalEnd) / 8) {
            ctx.fill(CGRect(x: verticalEnd + 12 + index * 8, y: y, width: 4, height: 50))
        }
        y += 60

        label(ctx, "CHECKERBOARD 8 px | 2 px | 1 px", y: &y)
        checker(ctx, x: 12, y: y, cells: (8, 4), cell: 8)
        checker(ctx, x: 12 + 8 * 8 + 12, y: y, cells: (16, 16), cell: 2)
        checker(ctx, x: 12 + 8 * 8 + 12 + 32 + 12, y: y, cells: (32, 32), cell: 1)
        y += 44

        label(ctx, "GRADIENT 256 steps | 16 bars", y: &y)
        for column in 0..<(width - 24) {
            let level = CGFloat(column) / CGFloat(width - 25)
            ctx.setFillColor(gray: level, alpha: 1)
            ctx.fill(CGRect(x: 12 + column, y: y, width: 1, height: 32))
        }
        y += 38
        let barWidth = (width - 24) / 16
        for bar in 0..<16 {
            ctx.setFillColor(gray: CGFloat(bar) / 15, alpha: 1)
            ctx.fill(CGRect(x: 12 + bar * barWidth, y: y, width: barWidth, height: 32))
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        y += 44

        ctx.setShouldAntialias(true)
        label(ctx, "CIRCLES", y: &y, crisp: false)
        ctx.setLineWidth(2)
        let centerY = y + 70
        for radius in [64, 48, 32, 16] {
            ctx.strokeEllipse(in: CGRect(x: CGFloat(82 - radius), y: CGFloat(centerY - radius), width: CGFloat(radius * 2), height: CGFloat(radius * 2)))
        }
        ctx.fillEllipse(in: CGRect(x: 220, y: centerY - 40, width: 80, height: 80))
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: 330, y: centerY - 40, width: 80, height: 80))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: 424, y: centerY - 40, width: 76, height: 76))
        y += 150

        label(ctx, "TEXT SIZES", y: &y, crisp: false)
        for size in [8, 10, 12, 16, 22, 32] {
            text(ctx, "The quick brown fox \(size)pt", size: CGFloat(size), bold: size == 22, leftAt: 12, baseline: y + size)
            y += size + 8
        }
        y += 6

        ctx.setShouldAntialias(false)
        label(ctx, "ORIENTATION: F must read normally", y: &y)
        ctx.fill(CGRect(x: 12, y: y, width: 12, height: 80))
        ctx.fill(CGRect(x: 12, y: y, width: 56, height: 12))
        ctx.fill(CGRect(x: 12, y: y + 34, width: 40, height: 12))
        ctx.setShouldAntialias(true)
        text(ctx, "<- LEFT edge", size: 14, bold: false, leftAt: 90, baseline: y + 20)
        text(ctx, "RIGHT edge ->", size: 14, bold: false, leftAt: width - 12 - 110, baseline: y + 70)
        y += 96

        ctx.setShouldAntialias(false)
        label(ctx, "RULER: tick every 8 dots, tall every 64", y: &y)
        for tick in stride(from: 0, to: width, by: 8) {
            let tall = tick % 64 == 0
            ctx.fill(CGRect(x: tick, y: y, width: 1, height: tall ? 24 : 10))
        }
        ctx.fill(CGRect(x: width - 1, y: y, width: 1, height: 24))
        y += 36

        return ctx.makeImage()
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw RasterError.unreadableImage("cannot create \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw RasterError.unreadableImage("cannot write \(url.path)")
        }
    }

    private static func label(_ ctx: CGContext, _ string: String, y: inout Int, crisp: Bool = true) {
        ctx.setShouldAntialias(true)
        text(ctx, string, size: 11, bold: true, leftAt: 12, baseline: y + 11)
        ctx.setShouldAntialias(!crisp)
        y += 18
    }

    private static func checker(_ ctx: CGContext, x: Int, y: Int, cells: (Int, Int), cell: Int) {
        for row in 0..<cells.1 {
            for column in 0..<cells.0 where (row + column) % 2 == 0 {
                ctx.fill(CGRect(x: x + column * cell, y: y + row * cell, width: cell, height: cell))
            }
        }
    }

    private static func line(_ string: String, size: CGFloat, bold: Bool) -> CTLine {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary))
    }

    private static func text(_ ctx: CGContext, _ string: String, size: CGFloat, bold: Bool, leftAt x: Int, baseline: Int) {
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line(string, size: size, bold: bold), ctx)
    }

    private static func text(_ ctx: CGContext, _ string: String, size: CGFloat, bold: Bool, centeredIn width: Int, baseline: Int) {
        let ctLine = line(string, size: size, bold: bold)
        let lineWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (CGFloat(width) - lineWidth) / 2, y: CGFloat(baseline))
        CTLineDraw(ctLine, ctx)
    }
}
