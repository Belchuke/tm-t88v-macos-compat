import Foundation
import Testing
@testable import TMT88VCore

struct DiagnosticsTests {
    func outcome(_ document: Data, model: PrinterModel = .tmT88V80mm) throws -> PrintOutcome {
        try PrintService(model: model, output: CapturingOutput()).print(document: document, declaredFormat: "image/urf", jobID: 1)
    }

    @Test func reportsPageGeometryTrimScaleAndCut() throws {
        let result = try outcome(Fixture.urf(width: 510, height: 2100) { _, y in y < 30 ? 0 : 255 })
        let page = try #require(result.pageDetails.first)
        #expect(page.widthPx == 510 && page.heightPx == 2100)
        #expect(page.widthMM == 72.0)
        #expect(page.heightMM == 296.3)
        #expect(page.dpiX == 180 && page.dpiY == 180)
        #expect(page.trimmedHeightPx == 30)
        #expect(page.rasterWidth == 512 && page.rasterHeight == 30)
        #expect(page.scale == "none" && page.scaleFactor == 1.0)
        #expect(page.offsetX == 1)
        #expect(page.cut)
        #expect(result.cuts == 1)
    }

    @Test func reportsDownscale() throws {
        let page = try #require(try outcome(Fixture.urf(width: 1024, height: 40) { _, _ in 0 }).pageDetails.first)
        #expect(page.scale == "down")
        #expect(page.scaleFactor == 0.5)
        #expect(page.offsetX == 0)
        #expect(page.rasterWidth == 512 && page.rasterHeight == 20)
    }

    @Test func blankPagesAreReportedAndNotCut() throws {
        let result = try outcome(Fixture.urf(width: 510, height: 50, pages: 2) { _, _ in 255 })
        #expect(result.pageDetails.count == 2)
        #expect(result.pageDetails.allSatisfy { $0.blank && !$0.cut })
        #expect(result.cuts == 0)
    }

    @Test func cutsEqualPrintedPages() throws {
        let result = try outcome(Fixture.urf(width: 510, height: 10, pages: 3) { _, y in y < 5 ? 0 : 255 })
        #expect(result.pages == 3 && result.cuts == 3)
        #expect(result.pageDetails.map(\.page) == [1, 2, 3])
    }

    @Test func noCutModelReportsZeroCuts() throws {
        var model = PrinterModel.tmT88V80mm
        model.cutMode = .none
        #expect(try outcome(Fixture.urf(width: 510, height: 10) { _, _ in 0 }, model: model).cuts == 0)
    }

    @Test func requestedAttributesDescribeMediaAndCollections() {
        let operation = IppGroup(tag: IppTag.operationGroup, attributes: [IppAttribute("document-format", .mimeMediaType("image/urf"))])
        let job = IppGroup(tag: IppTag.jobGroup, attributes: [
            IppAttribute("media", .keyword("custom_72x297mm_72x297mm")),
            IppAttribute("media-col", .collection([
                IppAttribute("media-size", .collection([IppAttribute("x-dimension", .integer(7200)), IppAttribute("y-dimension", .integer(29700))])),
                IppAttribute("media-type", .keyword("continuous")),
            ])),
            IppAttribute("printer-resolution", .resolution(cross: 180, feed: 180, units: 3)),
            IppAttribute("copies", .integer(1)),
            IppAttribute("job-name", .name("SECRET")),
        ])
        let described = IppRequestHandler.requestedAttributes([operation, job])
        #expect(described["media"] == "custom_72x297mm_72x297mm")
        #expect(described["media-col"] == "{media-size={x-dimension=7200 y-dimension=29700} media-type=continuous}")
        #expect(described["printer-resolution"] == "180x180dpi")
        #expect(described["copies"] == "1")
        #expect(described["document-format"] == "image/urf")
        #expect(described["job-name"] == nil)
    }

    @Test func logRecordsDiagnosticsButNeverJobOrUserNames() throws {
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("tmt88v-log-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let log = ServiceLog(fileURL: logURL, echoToStderr: false)
        let output = CapturingOutput()
        let jobs = JobManager(service: PrintService(model: .tmT88V80mm, output: output), log: log)
        let handler = IppRequestHandler(config: IppServerConfig(), jobs: jobs, log: log)

        let message = Fixture.ippRequest(IppOperation.printJob, extra: [
            IppAttribute("job-name", .name("SECRET-JOB-NAME")),
            IppAttribute("requesting-user-name", .name("secret-user")),
        ], document: Fixture.urf(width: 510, height: 20) { _, y in y < 3 ? 0 : 255 })
        _ = handler.handle(message)
        #expect(waitUntil { jobs.job(id: 1)?.state == .completed })
        Thread.sleep(forTimeInterval: 0.1)

        let text = try String(contentsOf: logURL, encoding: .utf8)
        #expect(text.contains("\"event\":\"ipp_request\""))
        #expect(text.contains("\"operation\":\"Print-Job\""))
        #expect(text.contains("\"event\":\"job_received\""))
        #expect(text.contains("\"event\":\"job_completed\""))
        #expect(text.contains("\"cuts\":1"))
        #expect(text.contains("page_details"))
        #expect(text.contains("\"page_px\":\"510x20\""))
        #expect(text.contains("\"raster\":\"512x3\""))
        #expect(!text.contains("SECRET"))
        #expect(!text.contains("secret"))
    }
}
