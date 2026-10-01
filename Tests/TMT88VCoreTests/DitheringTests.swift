import Testing
@testable import TMT88VCore

struct DitheringTests {
    static let widths = [1, 7, 8, 9, 15, 16, 17, 511, 512]

    @Test(arguments: widths)
    func rowBytesArePaddedUp(width: Int) {
        #expect(MonoBitmap.rowBytes(forWidth: width) == (width + 7) / 8)
    }

    @Test(arguments: widths)
    func allBlackSetsExactlyTheImageBitsAndLeavesPaddingClear(width: Int) {
        let image = GrayImage(width: width, height: 2, fill: 0)
        let bitmap = Dithering.apply(image, mode: .threshold)
        #expect(bitmap.rowBytes == (width + 7) / 8)
        for y in 0..<2 {
            let row = Array(bitmap.data[(y * bitmap.rowBytes)..<((y + 1) * bitmap.rowBytes)])
            let setBits = row.reduce(0) { $0 + $1.nonzeroBitCount }
            #expect(setBits == width)
            if width % 8 != 0 {
                let paddingMask = UInt8(0xFF >> (width % 8))
                #expect(row.last! & paddingMask == 0)
            }
        }
    }

    @Test(arguments: widths)
    func allWhiteIsAllZero(width: Int) {
        let image = GrayImage(width: width, height: 3, fill: 255)
        #expect(Dithering.apply(image, mode: .threshold).data.allSatisfy { $0 == 0 })
        #expect(Dithering.apply(image, mode: .floydSteinberg).data.allSatisfy { $0 == 0 })
    }

    @Test(arguments: widths)
    func eachSinglePixelLandsOnItsOwnBit(width: Int) {
        for x in 0..<width {
            var image = GrayImage(width: width, height: 1, fill: 255)
            image.pixels[x] = 0
            let bitmap = Dithering.apply(image, mode: .threshold)
            let expectedByte = x / 8
            for (index, byte) in bitmap.data.enumerated() {
                #expect(byte == (index == expectedByte ? UInt8(0x80 >> (x % 8)) : 0))
            }
        }
    }

    @Test func bitOrderIsMostSignificantFirst() {
        var image = GrayImage(width: 8, height: 1, fill: 255)
        image.pixels[0] = 0
        image.pixels[7] = 0
        #expect(Dithering.apply(image, mode: .threshold).data == [0b1000_0001])
    }

    @Test func blackIsOneAndWhiteIsZero() {
        let image = GrayImage(width: 8, height: 1, pixels: [0, 255, 0, 255, 0, 255, 0, 255])
        #expect(Dithering.apply(image, mode: .threshold).data == [0b1010_1010])
    }

    @Test func thresholdBoundary() {
        let image = GrayImage(width: 3, height: 1, pixels: [127, 128, 129])
        #expect(Dithering.apply(image, mode: .threshold, threshold: 128).data == [0b1000_0000])
        #expect(Dithering.apply(image, mode: .threshold, threshold: 129).data == [0b1100_0000])
    }

    @Test func rowsStayIndependent() {
        let image = GrayImage(width: 9, height: 2, pixels: [UInt8](repeating: 0, count: 9) + [UInt8](repeating: 255, count: 9))
        #expect(Dithering.apply(image, mode: .threshold).data == [0xFF, 0x80, 0x00, 0x00])
    }

    @Test func floydSteinbergMidGrayIsRoughlyHalfBlack() {
        let image = GrayImage(width: 64, height: 64, fill: 128)
        let bitmap = Dithering.apply(image, mode: .floydSteinberg)
        let black = bitmap.data.reduce(0) { $0 + $1.nonzeroBitCount }
        let ratio = Double(black) / Double(64 * 64)
        #expect(ratio > 0.4 && ratio < 0.6)
    }

    @Test func floydSteinbergDarkGrayIsDarkerThanLightGray() {
        func blackCount(_ level: UInt8) -> Int {
            Dithering.apply(GrayImage(width: 64, height: 64, fill: level), mode: .floydSteinberg)
                .data.reduce(0) { $0 + $1.nonzeroBitCount }
        }
        #expect(blackCount(64) > blackCount(128))
        #expect(blackCount(128) > blackCount(192))
    }

    @Test func floydSteinbergIsDeterministic() {
        let pixels = (0..<(40 * 40)).map { UInt8(($0 * 7) % 256) }
        let image = GrayImage(width: 40, height: 40, pixels: pixels)
        #expect(Dithering.apply(image, mode: .floydSteinberg) == Dithering.apply(image, mode: .floydSteinberg))
    }

    @Test func floydSteinbergKeepsPaddingBitsClear() {
        let image = GrayImage(width: 9, height: 9, fill: 100)
        let bitmap = Dithering.apply(image, mode: .floydSteinberg)
        for y in 0..<9 {
            #expect(bitmap.data[y * 2 + 1] & 0x7F == 0)
        }
    }
}
