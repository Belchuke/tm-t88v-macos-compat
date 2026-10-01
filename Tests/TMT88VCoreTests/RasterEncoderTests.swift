import CoreGraphics
import Foundation
import Testing
@testable import TMT88VCore

struct RasterEncoderTests {
    static func bitmap(width: Int, height: Int, fillByte: UInt8 = 0xAA) -> MonoBitmap {
        let rowBytes = MonoBitmap.rowBytes(forWidth: width)
        return MonoBitmap(width: width, height: height, data: [UInt8](repeating: fillByte, count: rowBytes * height))
    }

    @Test func singleBandHeaderAndPayload() {
        let bytes = [UInt8](RasterEncoder.encode(Self.bitmap(width: 16, height: 3)))
        #expect(Array(bytes.prefix(8)) == [0x1D, 0x76, 0x30, 0x00, 2, 0, 3, 0])
        #expect(Array(bytes.dropFirst(8)) == [UInt8](repeating: 0xAA, count: 6))
    }

    @Test func splitsIntoBandsWithRemainder() {
        let bytes = [UInt8](RasterEncoder.encode(Self.bitmap(width: 8, height: 300), bandHeight: 128))
        let header = [0x1D, 0x76, 0x30, 0x00].map(UInt8.init)
        #expect(Array(bytes[0..<8]) == header + [1, 0, 128, 0])
        let second = 8 + 128
        #expect(Array(bytes[second..<(second + 8)]) == header + [1, 0, 128, 0])
        let third = second + 8 + 128
        #expect(Array(bytes[third..<(third + 8)]) == header + [1, 0, 44, 0])
        #expect(bytes.count == third + 8 + 44)
    }

    @Test func widthBytesUseTwoByteLittleEndian() {
        let bytes = [UInt8](RasterEncoder.encode(Self.bitmap(width: 2100, height: 1)))
        #expect(bytes[4] == UInt8(263 & 0xFF))
        #expect(bytes[5] == 1)
    }

    @Test func bandsPreserveRowOrder() {
        var data: [UInt8] = []
        for row in 0..<5 { data.append(UInt8(row + 1)) }
        let bytes = [UInt8](RasterEncoder.encode(MonoBitmap(width: 8, height: 5, data: data), bandHeight: 2))
        var rows: [UInt8] = []
        var offset = 0
        while offset < bytes.count {
            let count = Int(bytes[offset + 6])
            rows.append(contentsOf: bytes[(offset + 8)..<(offset + 8 + count)])
            offset += 8 + count
        }
        #expect(rows == [1, 2, 3, 4, 5])
    }

    @Test func emptyBitmapEncodesToNothing() {
        #expect(RasterEncoder.encode(Self.bitmap(width: 0, height: 0)).isEmpty)
    }

    @Test func receiptIsInitRasterFeedCut() throws {
        let data = [UInt8](try RasterReceipt.build(bitmap: Self.bitmap(width: 8, height: 1), model: .tmT88V80mm))
        #expect(Array(data.prefix(2)) == [0x1B, 0x40])
        #expect(Array(data.suffix(4)) == [0x1D, 0x56, 66, 0])
        #expect(Array(data.suffix(4 + 3)).prefix(3) == [0x1B, 0x64, 3])
    }

    @Test func receiptRejectsBitmapWiderThanPrinter() {
        #expect(throws: RasterError.bitmapWiderThanPrinter(width: 513, maxWidth: 512)) {
            try RasterReceipt.build(bitmap: Self.bitmap(width: 513, height: 1), model: .tmT88V80mm)
        }
        #expect(throws: Never.self) {
            try RasterReceipt.build(bitmap: Self.bitmap(width: 512, height: 1), model: .tmT88V80mm)
        }
    }
}

struct RasterProcessorTests {
    static func solidImage(width: Int, height: Int, gray: UInt8) -> CGImage {
        let pixels = [UInt8](repeating: gray, count: width * height)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    @Test func wideImageShrinksPreservingAspect() throws {
        let size = try RasterProcessor.targetSize(sourceWidth: 1024, sourceHeight: 300, maxWidth: 512, mode: .fit)
        #expect(size.width == 512 && size.height == 150)
    }

    @Test func narrowImageIsNotStretched() throws {
        let size = try RasterProcessor.targetSize(sourceWidth: 100, sourceHeight: 40, maxWidth: 512, mode: .fit)
        #expect(size.width == 100 && size.height == 40)
    }

    @Test func exactWidthIsUntouched() throws {
        let size = try RasterProcessor.targetSize(sourceWidth: 512, sourceHeight: 77, maxWidth: 512, mode: .fit)
        #expect(size.width == 512 && size.height == 77)
    }

    @Test func actualSizeRejectsOversizedImage() {
        #expect(throws: RasterError.imageTooWide(width: 600, maxWidth: 512)) {
            try RasterProcessor.targetSize(sourceWidth: 600, sourceHeight: 10, maxWidth: 512, mode: .actualSize)
        }
    }

    @Test func zeroDimensionsAreRejected() {
        #expect(throws: RasterError.invalidDimensions(width: 0, height: 5)) {
            try RasterProcessor.targetSize(sourceWidth: 0, sourceHeight: 5, maxWidth: 512, mode: .fit)
        }
    }

    @Test func smallImageIsCenteredOnFullWidthCanvas() throws {
        let gray = try RasterProcessor.renderGray(Self.solidImage(width: 100, height: 4, gray: 0), canvasWidth: 512)
        #expect(gray.width == 512 && gray.height == 4)
        let row = Array(gray.pixels[0..<512])
        #expect(row[205] == 255)
        #expect(row[206] == 0)
        #expect(row[305] == 0)
        #expect(row[306] == 255)
    }

    @Test func outputNeverExceedsPrinterWidth() throws {
        for width in [1, 7, 8, 9, 511, 512, 513, 2000] {
            let bitmap = try RasterProcessor.process(Self.solidImage(width: width, height: 3, gray: 0), model: .tmT88V80mm)
            #expect(bitmap.width <= 512)
        }
    }

    @Test func narrowPaperLimitsWidthTo360() throws {
        let bitmap = try RasterProcessor.process(Self.solidImage(width: 800, height: 8, gray: 0), model: .tmT88V58mm)
        #expect(bitmap.width == 360)
    }

    @Test func tallImagesAreRejected() {
        var options = RasterOptions()
        options.maxHeight = 10
        #expect(throws: RasterError.imageTooTall(height: 11, maxHeight: 10)) {
            try RasterProcessor.process(Self.solidImage(width: 8, height: 11, gray: 0), model: .tmT88V80mm, options: options)
        }
    }

    @Test func blackSourceProducesBlackBitsAndWhiteStaysClear() throws {
        let black = try RasterProcessor.process(Self.solidImage(width: 512, height: 2, gray: 0), model: .tmT88V80mm)
        #expect(black.data.allSatisfy { $0 == 0xFF })
        let white = try RasterProcessor.process(Self.solidImage(width: 512, height: 2, gray: 255), model: .tmT88V80mm)
        #expect(white.data.allSatisfy { $0 == 0 })
    }

    @Test func testPatternFitsPrinterAndKeepsEdgePixels() throws {
        let pattern = try #require(TestPattern.make(width: 512))
        #expect(pattern.width == 512)
        let bitmap = try RasterProcessor.process(pattern, model: .tmT88V80mm)
        #expect(bitmap.width == 512)
        #expect(bitmap.isBlack(x: 0, y: 500))
        #expect(bitmap.isBlack(x: 511, y: 500))
        #expect(bitmap.isBlack(x: 100, y: 0))
        #expect(bitmap.isBlack(x: 100, y: bitmap.height - 1))
    }

    @Test func testPatternIsDeterministic() throws {
        let a = try RasterProcessor.process(try #require(TestPattern.make()), model: .tmT88V80mm)
        let b = try RasterProcessor.process(try #require(TestPattern.make()), model: .tmT88V80mm)
        #expect(a == b)
    }
}
