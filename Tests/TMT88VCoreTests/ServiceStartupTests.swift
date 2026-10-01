import Foundation
import Testing
@testable import TMT88VCore

struct ServiceStartupTests {
    static let absentPrinter = PrinterModel(
        name: "Absent", usbVendorID: 0x0001, usbProductNames: ["NO-SUCH-PRINTER"], dpi: 180,
        paperWidthMM: 80, printableWidthMM: 72, dotsPerLine: 512, cutMode: .partial, cutFeedUnits: 0
    )

    func makeServer(model: PrinterModel, log: ServiceLog) throws -> (IppHTTPServer, JobManager) {
        var config = IppServerConfig()
        config.port = 0
        config.model = model
        let jobs = JobManager(service: PrintService(model: model, output: UsbOutput(model: model)), log: log)
        let server = IppHTTPServer(config: config, handler: IppRequestHandler(config: config, jobs: jobs, log: log), log: log)
        try server.start()
        return (server, jobs)
    }

    @Test func listenerStartsAndAnswersWithNoPrinterAttached() throws {
        let (server, _) = try makeServer(model: Self.absentPrinter, log: ServiceLog(echoToStderr: false))
        defer { server.stop() }
        let reply = try #require(LoopbackServerTests.request(port: server.port, body: Fixture.ippRequest(IppOperation.getPrinterAttributes)))
        #expect(reply.status == 200)
        #expect(try Fixture.decodeResponse(reply.body).code == IppStatus.ok)
    }

    @Test func jobForAnAbsentPrinterFailsCleanlyAndServiceKeepsAnswering() throws {
        let (server, jobs) = try makeServer(model: Self.absentPrinter, log: ServiceLog(echoToStderr: false))
        defer { server.stop() }
        let document = Fixture.urf(width: 510, height: 10) { _, y in y < 3 ? 0 : 255 }
        let reply = try #require(LoopbackServerTests.request(
            port: server.port,
            body: Fixture.ippRequest(IppOperation.printJob, printerURI: "ipp://127.0.0.1:\(server.port)/ipp/print", document: document)
        ))
        #expect(try Fixture.decodeResponse(reply.body).code == IppStatus.ok)
        #expect(waitUntil { jobs.job(id: 1)?.state == .aborted })
        #expect(jobs.job(id: 1)?.message.contains("printer_not_found") == true)
        let again = try #require(LoopbackServerTests.request(port: server.port, body: Fixture.ippRequest(IppOperation.getPrinterAttributes)))
        #expect(again.status == 200)
    }

    @Test func serviceStartsWhenLogFileCannotBeWritten() throws {
        let log = ServiceLog(fileURL: URL(fileURLWithPath: "/System/not-writable/service.log"), echoToStderr: false)
        let (server, _) = try makeServer(model: Self.absentPrinter, log: log)
        defer { server.stop() }
        log.event("listening")
        let reply = try #require(LoopbackServerTests.request(port: server.port, body: Fixture.ippRequest(IppOperation.getPrinterAttributes)))
        #expect(reply.status == 200)
    }

    @Test func quietLogWritesToFileAndNotToStderr() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tmt88v-quiet-\(UUID().uuidString)/service.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = ServiceLog(fileURL: url, echoToStderr: false)
        log.event("listening", ["x": 1])
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"event\":\"listening\""))
    }
}
