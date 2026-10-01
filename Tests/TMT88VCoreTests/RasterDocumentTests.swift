import Foundation
import Testing
@testable import TMT88VCore

struct RasterDocumentTests {
    @Test func detectsFormatsByMagic() {
        #expect(RasterFormat.detect(Data("UNIRAST\0xxxx".utf8)) == .urf)
        #expect(RasterFormat.detect(Data("RaS2xxxx".utf8)) == .pwg)
        #expect(RasterFormat.detect(Data("%PDF".utf8)) == nil)
        #expect(RasterFormat.detect(Data()) == nil)
    }

    @Test func parsesURFPixelsAndDpi() throws {
        let data = Fixture.urf(width: 6, height: 3, dpi: 180) { x, y in UInt8(x * 10 + y) }
        let page = try #require(try RasterDocument.parse(data).first)
        #expect(page.dpiX == 180)
        #expect(page.image.width == 6 && page.image.height == 3)
        #expect(page.image.pixels == (0..<3).flatMap { y in (0..<6).map { x in UInt8(x * 10 + y) } })
    }

    @Test func parsesMultiPageURF() throws {
        let data = Fixture.urf(width: 4, height: 2, pages: 3) { _, _ in 0 }
        #expect(try RasterDocument.parse(data).count == 3)
    }

    @Test func urfLiteralRunRepeatRunWhiteFillAndLineRepeat() throws {
        var data = Data("UNIRAST\0".utf8)
        data.append(contentsOf: Fixture.be32(1))
        var header = [UInt8](repeating: 0, count: 32)
        header[0] = 8
        header.replaceSubrange(12..<16, with: Fixture.be32(8))
        header.replaceSubrange(16..<20, with: Fixture.be32(4))
        header.replaceSubrange(20..<24, with: Fixture.be32(180))
        data.append(contentsOf: header)
        data.append(contentsOf: [1, 0xFE, 1, 2, 3, 0x80])
        data.append(contentsOf: [0, 3, 9, 0x80])
        data.append(contentsOf: [0, 0x80])
        let image = try #require(try RasterDocument.parse(data).first).image
        #expect(Array(image.pixels[0..<8]) == [1, 2, 3, 255, 255, 255, 255, 255])
        #expect(Array(image.pixels[8..<16]) == [1, 2, 3, 255, 255, 255, 255, 255])
        #expect(Array(image.pixels[16..<24]) == [9, 9, 9, 9, 255, 255, 255, 255])
        #expect(Array(image.pixels[24..<32]) == [UInt8](repeating: 255, count: 8))
    }

    @Test func urfRGBConvertsToLuminance() throws {
        var data = Data("UNIRAST\0".utf8)
        data.append(contentsOf: Fixture.be32(1))
        var header = [UInt8](repeating: 0, count: 32)
        header[0] = 24; header[1] = 1
        header.replaceSubrange(12..<16, with: Fixture.be32(3))
        header.replaceSubrange(16..<20, with: Fixture.be32(1))
        header.replaceSubrange(20..<24, with: Fixture.be32(180))
        data.append(contentsOf: header)
        data.append(contentsOf: [0, 0xFE, 255, 255, 255, 0, 0, 0, 0, 255, 0, 0, 0])
        let pixels = try #require(try RasterDocument.parse(data).first).image.pixels
        #expect(pixels[0] == 255 && pixels[1] == 0)
    }

    @Test func parsesPWGGrayAndOneBit() throws {
        let gray = try #require(try RasterDocument.parse(Fixture.pwgGray(width: 5, height: 2) { x, _ in UInt8(x * 50) }).first)
        #expect(gray.image.pixels.prefix(5) == [0, 50, 100, 150, 200])
        #expect(gray.dpiX == 180)

        var oneBit = Data("RaS2".utf8)
        oneBit.append(Fixture.pwgHeader(width: 9, height: 1, bitsPerPixel: 1, colorSpace: 3))
        oneBit.append(contentsOf: [0, 0xFF, 0b1010_0000, 0x80])
        let black = try #require(try RasterDocument.parse(oneBit).first).image.pixels
        #expect(black == [0, 255, 0, 255, 255, 255, 255, 255, 0])
    }

    @Test func rejectsUnsupportedAndOversizedPages() {
        var cmyk = Data("RaS2".utf8)
        cmyk.append(Fixture.pwgHeader(width: 4, height: 1, bitsPerPixel: 32, colorSpace: 6))
        #expect(throws: RasterDocumentError.self) { try RasterDocument.parse(cmyk) }

        var huge = Data("UNIRAST\0".utf8)
        huge.append(contentsOf: Fixture.be32(1))
        var header = [UInt8](repeating: 0, count: 32)
        header[0] = 8
        header.replaceSubrange(12..<16, with: Fixture.be32(100_000))
        header.replaceSubrange(16..<20, with: Fixture.be32(100_000))
        huge.append(contentsOf: header)
        #expect(throws: RasterDocumentError.tooLarge("100000x100000 pixels")) { try RasterDocument.parse(huge) }
    }

    @Test func truncationAtEveryByteIsAnErrorNotACrash() {
        let data = Fixture.urf(width: 5, height: 3) { x, _ in UInt8(x) }
        for length in 0..<data.count {
            #expect(throws: RasterDocumentError.self) { try RasterDocument.parse(data.prefix(length)) }
        }
    }

    @Test func runOverflowingLineIsRejected() {
        var data = Data("UNIRAST\0".utf8)
        data.append(contentsOf: Fixture.be32(1))
        var header = [UInt8](repeating: 0, count: 32)
        header[0] = 8
        header.replaceSubrange(12..<16, with: Fixture.be32(4))
        header.replaceSubrange(16..<20, with: Fixture.be32(1))
        data.append(contentsOf: header)
        data.append(contentsOf: [0, 20, 7])
        #expect(throws: RasterDocumentError.self) { try RasterDocument.parse(data) }
    }

    @Test func trimmingRemovesTrailingWhiteOnly() {
        var image = GrayImage(width: 4, height: 6, fill: 255)
        image.pixels[2 * 4 + 1] = 0
        #expect(image.trimmingTrailingWhite()?.height == 3)
        #expect(GrayImage(width: 4, height: 6, fill: 255).trimmingTrailingWhite() == nil)
        #expect(GrayImage(width: 4, height: 6, fill: 251).trimmingTrailingWhite() == nil)
        #expect(GrayImage(width: 4, height: 6, fill: 249).trimmingTrailingWhite()?.height == 6)
    }

    @Test func randomGarbageAfterMagicNeverCrashes() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var data = Data(Bool.random() ? "UNIRAST\0".utf8 : "RaS2".utf8)
            data.append(contentsOf: (0..<Int.random(in: 0..<300, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
            _ = try? RasterDocument.parse(data)
        }
    }
}
