import Foundation
import Testing
@testable import TMT88VCore

struct PrinterStatusTests {
    static func responder(_ replies: [UInt8: UInt8]) -> (Data) -> Data? {
        { request in
            guard request.count == 3, request[0] == 0x10, request[1] == 0x04, let reply = replies[request[2]] else { return nil }
            return Data([reply])
        }
    }

    @Test func readyPrinter() throws {
        let transport = RecordingTransport()
        transport.responder = Self.responder([1: 0x16, 2: 0x12, 3: 0x12, 4: 0x12])
        let status = try PrinterStatusQuery.query(transport)
        #expect(status.summary == "READY")
        #expect(!status.blocksPrinting)
        #expect([UInt8](transport.written) == [0x10, 0x04, 1, 0x10, 0x04, 2, 0x10, 0x04, 3, 0x10, 0x04, 4])
    }

    @Test func coverOpenAndPaperOut() throws {
        let transport = RecordingTransport()
        transport.responder = Self.responder([1: 0x1E, 2: 0x36, 3: 0x12, 4: 0x72])
        let status = try PrinterStatusQuery.query(transport)
        #expect(status.offline)
        #expect(status.coverOpen)
        #expect(status.paperEnd)
        #expect(status.blocksPrinting)
        #expect(status.summary.contains("COVER_OPEN"))
        #expect(status.summary.contains("PAPER_OUT"))
    }

    @Test func rejectsMalformedResponse() {
        let transport = RecordingTransport()
        transport.responder = { _ in Data([0xFF]) }
        #expect(throws: UsbError.self) { try PrinterStatusQuery.query(transport) }
    }

    @Test func timesOutWhenPrinterNeverAnswers() {
        let transport = RecordingTransport()
        #expect(throws: UsbError.self) { try PrinterStatusQuery.query(transport, timeout: 0.1) }
    }

    @Test func staleBytesAreDrainedBeforeQuery() throws {
        let transport = RecordingTransport()
        var first = true
        transport.responder = { request in
            defer { first = false }
            return first ? Data([0x12, 0x12, 0x36]) : Self.responder([1: 0x16, 2: 0x12, 3: 0x12, 4: 0x12])(request)
        }
        try transport.write(Data([0x00]))
        let status = try PrinterStatusQuery.query(transport)
        #expect(status.summary == "READY")
    }

    @Test func modelMatchingIsCaseInsensitive() {
        #expect(PrinterModel.tmT88V80mm.matches(productName: "tm-t88v "))
        #expect(!PrinterModel.tmT88V80mm.matches(productName: "TM-T88IV"))
        #expect(!PrinterModel.tmT88V80mm.matches(productName: nil))
    }
}
