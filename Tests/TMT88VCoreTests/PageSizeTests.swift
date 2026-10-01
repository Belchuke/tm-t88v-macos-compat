import Foundation
import Testing
@testable import TMT88VCore

struct PageSizeTests {
    func mediaSizes(_ model: PrinterModel) -> [IppAttribute] {
        IppPrinterAttributes.build(config: { var c = IppServerConfig(); c.model = model; return c }(), queuedJobs: 0, processing: false, startTime: Date())
    }

    @Test func eightyMillimetreMediaIsSeventyTwoMillimetresWide() {
        let profile = IppMediaProfile(model: .tmT88V80mm)
        #expect(profile.widthHundredthsMM == 7200)
        #expect(profile.defaultName == "custom_roll-72_72x297mm")
        #expect(profile.minName == "custom_min_72x25.4mm")
        #expect(profile.maxName == "custom_max_72x2000mm")
    }

    @Test func fiftyEightMillimetreProfileUsesItsOwnWidth() {
        #expect(IppMediaProfile(model: .tmT88V58mm).widthHundredthsMM == 5080)
    }

    @Test func neverAdvertisesOfficeMedia() {
        let attributes = mediaSizes(.tmT88V80mm)
        let names = attributes.first { $0.name == "media-supported" }!.values.compactMap(\.string)
        #expect(!names.contains { $0.contains("a4") || $0.contains("letter") || $0.contains("iso_") || $0.contains("na_") })
        let defaultMedia = attributes.first { $0.name == "media-default" }!.values.first?.string
        #expect(defaultMedia == "custom_roll-72_72x297mm")
    }

    @Test func everyMediaSizeIsExactlyOneWidthWithZeroMargins() {
        let attributes = mediaSizes(.tmT88V80mm)
        let sizes = attributes.first { $0.name == "media-size-supported" }!.values
        #expect(sizes.count == 2)
        for case .collection(let members) in sizes {
            #expect(members.first { $0.name == "x-dimension" }?.values == [.integer(7200)])
        }
        let range = sizes.compactMap { value -> IppValue? in
            guard case .collection(let members) = value else { return nil }
            return members.first { $0.name == "y-dimension" }?.values.first
        }
        #expect(range.contains(.range(2540, 200_000)))
        for margin in ["media-bottom-margin-supported", "media-left-margin-supported", "media-right-margin-supported", "media-top-margin-supported"] {
            #expect(attributes.first { $0.name == margin }?.values == [.integer(0)])
        }
    }

    @Test func advertisedWidthMatchesRasterWidthAt180Dpi() {
        let widthPixels = Double(IppMediaProfile(model: .tmT88V80mm).widthHundredthsMM) / 2540 * 180
        #expect(Int(widthPixels.rounded()) == 510)
        #expect(Int(widthPixels.rounded()) <= PrinterModel.tmT88V80mm.dotsPerLine)
    }

    @Test func cupsSizedPageIsCenteredNotStretchedOrScaled() throws {
        let page = Fixture.urf(width: 510, height: 4) { x, _ in x == 0 ? 0 : 255 }
        let pages = try RasterDocument.parse(page)
        let bitmap = try RasterProcessor.process(gray: pages[0].image, model: .tmT88V80mm)
        #expect(bitmap.width == 512)
        #expect(bitmap.isBlack(x: 1, y: 0))
        #expect(!bitmap.isBlack(x: 0, y: 0))
        #expect(!bitmap.isBlack(x: 2, y: 0))
    }

    @Test func fiveHundredTwelveWidePageKeepsEveryDot() throws {
        let pages = try RasterDocument.parse(Fixture.urf(width: 512, height: 2) { x, _ in x % 2 == 0 ? 0 : 255 })
        let bitmap = try RasterProcessor.process(gray: pages[0].image, model: .tmT88V80mm)
        #expect(bitmap.width == 512)
        #expect(bitmap.data.prefix(64).allSatisfy { $0 == 0b1010_1010 })
    }

    @Test func widerPageIsScaledDownNeverCropped() throws {
        let pages = try RasterDocument.parse(Fixture.urf(width: 1024, height: 100) { _, _ in 0 })
        let bitmap = try RasterProcessor.process(gray: pages[0].image, model: .tmT88V80mm)
        #expect(bitmap.width == 512)
        #expect(bitmap.height == 50)
        #expect(bitmap.data.allSatisfy { $0 == 0xFF })
    }

    @Test func fiftyEightMillimetrePrinterScalesWidePagesTo360() throws {
        let pages = try RasterDocument.parse(Fixture.urf(width: 510, height: 10) { _, _ in 0 })
        let bitmap = try RasterProcessor.process(gray: pages[0].image, model: .tmT88V58mm)
        #expect(bitmap.width == 360)
    }
}
