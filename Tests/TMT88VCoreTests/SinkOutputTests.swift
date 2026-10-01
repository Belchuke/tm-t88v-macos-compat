import Foundation
import Testing
@testable import TMT88VCore

struct SinkOutputTests {
    static func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tmt88v-sink-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writesToAFilePath() throws {
        let dir = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("out.escpos")
        let sink = SinkOutput(path: file.path)
        _ = try sink.send(Data([1, 2, 3]), jobID: 1)
        _ = try sink.send(Data([4, 5]), jobID: 2)
        #expect(try Data(contentsOf: file) == Data([4, 5]))
    }

    @Test func writesPerJobFilesInADirectory() throws {
        let dir = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = SinkOutput(path: dir.path)
        _ = try sink.send(Data([1]), jobID: 1)
        _ = try sink.send(Data([2]), jobID: 2)
        #expect(try Data(contentsOf: dir.appendingPathComponent("job-1.escpos")) == Data([1]))
        #expect(try Data(contentsOf: dir.appendingPathComponent("job-2.escpos")) == Data([2]))
    }

    @Test func trailingSlashCreatesTheDirectory() throws {
        let dir = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.path + "/a/b/"
        _ = try SinkOutput(path: nested).send(Data([9]), jobID: 7)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a/b/job-7.escpos").path))
    }

    @Test func sinkReportsItselfAsNotUSB() {
        let output = SinkOutput(path: "/tmp/x")
        #expect(output.connectionName == "sink")
        #expect(UsbOutput(model: .tmT88V80mm).connectionName == "usb")
    }

    func run(_ document: Data, model: PrinterModel = .tmT88V80mm) throws -> (outcome: PrintOutcome, receipts: [DecodedReceipt], files: Int) {
        let dir = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = PrintService(model: model, output: SinkOutput(path: dir.path))
        let outcome = try service.print(document: document, declaredFormat: "image/urf", jobID: 1)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let receipts = try files.flatMap { try EscPosRasterDecoder.decode(Data(contentsOf: dir.appendingPathComponent($0))) }
        return (outcome, receipts, files.count)
    }

    @Test func trailingBlankPageAreaIsTrimmedAndOutputIsFullPrinterWidth() throws {
        let page = Fixture.urf(width: 510, height: 2100) { _, y in y < 30 ? 0 : 255 }
        let result = try run(page)
        let receipt = try #require(result.receipts.first)
        #expect(result.receipts.count == 1)
        #expect(receipt.bitmap.width == 512)
        #expect(receipt.bitmap.height == 30)
        #expect(receipt.cut)
        #expect(receipt.feedLines == 3)
        #expect(result.outcome.rasterWidth == 512)
        #expect(result.outcome.connection == "sink")
    }

    @Test func sinkContentMatchesTheSubmittedPixelsExactly() throws {
        let page = Fixture.urf(width: 510, height: 4) { x, y in (x + y) % 2 == 0 ? 0 : 255 }
        let bitmap = try #require(try run(page).receipts.first).bitmap
        for y in 0..<4 {
            #expect(!bitmap.isBlack(x: 0, y: y))
            #expect(!bitmap.isBlack(x: 511, y: y))
            for x in 0..<510 {
                #expect(bitmap.isBlack(x: x + 1, y: y) == ((x + y) % 2 == 0))
            }
        }
    }

    @Test func widePagesAreScaledDownToFiveHundredTwelveDots() throws {
        let page = Fixture.urf(width: 1024, height: 40) { _, _ in 0 }
        let bitmap = try #require(try run(page).receipts.first).bitmap
        #expect(bitmap.width == 512)
        #expect(bitmap.height == 20)
    }

    @Test func eachPageBecomesItsOwnCutReceipt() throws {
        let page = Fixture.urf(width: 510, height: 10, pages: 3) { _, y in y < 5 ? 0 : 255 }
        let result = try run(page)
        #expect(result.receipts.count == 3)
        #expect(result.receipts.allSatisfy { $0.cut && $0.bitmap.height == 5 })
        #expect(result.outcome.pages == 3)
    }

    @Test func blankDocumentsPrintNothing() throws {
        let result = try run(Fixture.urf(width: 510, height: 50) { _, _ in 255 })
        #expect(result.files == 0)
        #expect(result.outcome.blankPages == 1)
        #expect(result.outcome.encodedBytes == 0)
    }

    @Test func fiftyEightMillimetreModelProducesThreeHundredSixtyDots() throws {
        let page = Fixture.urf(width: 360, height: 10) { _, _ in 0 }
        let bitmap = try #require(try run(page, model: .tmT88V58mm).receipts.first).bitmap
        #expect(bitmap.width == 360)
    }

    @Test func pwgRasterRoutesThroughTheSamePipeline() throws {
        let bitmap = try #require(try run(Fixture.pwgGray(width: 510, height: 6) { _, y in y < 3 ? 0 : 255 }).receipts.first).bitmap
        #expect(bitmap.width == 512 && bitmap.height == 3)
    }

    @Test func nonRasterInputIsRejectedWithoutWritingAnything() throws {
        let dir = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = PrintService(model: .tmT88V80mm, output: SinkOutput(path: dir.path))
        #expect(throws: PrintFailure.self) { try service.print(document: Data("%PDF-1.4".utf8), declaredFormat: nil, jobID: 1) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}
