import Foundation
import Testing
@testable import TMT88VCore

struct EscPosEncoderTests {
    @Test func initializeIsEscAt() {
        let encoder = EscPosEncoder()
        encoder.initialize()
        #expect([UInt8](encoder.data) == [0x1B, 0x40])
    }

    @Test func lineAppendsLineFeed() {
        let encoder = EscPosEncoder()
        encoder.line("AB")
        #expect([UInt8](encoder.data) == [0x41, 0x42, 0x0A])
    }

    @Test func nonAsciiIsReplaced() {
        #expect(EscPosEncoder.asciiBytes("æ1") == [UInt8(ascii: "?"), UInt8(ascii: "1")])
    }

    @Test func feedSplitsAbove255() {
        let encoder = EscPosEncoder()
        encoder.feed(lines: 300)
        #expect([UInt8](encoder.data) == [0x1B, 0x64, 255, 0x1B, 0x64, 45])
    }

    @Test func cutCommands() {
        let partial = EscPosEncoder()
        partial.cut(.partial, feedUnits: 3)
        #expect([UInt8](partial.data) == [0x1D, 0x56, 66, 3])

        let full = EscPosEncoder()
        full.cut(.full)
        #expect([UInt8](full.data) == [0x1D, 0x56, 65, 0])

        let none = EscPosEncoder()
        none.cut(.none)
        #expect(none.data.isEmpty)
    }

    @Test func characterSizeClamps() {
        let encoder = EscPosEncoder()
        encoder.characterSize(width: 2, height: 9)
        #expect([UInt8](encoder.data) == [0x1D, 0x21, 0x17])
    }

    @Test func testReceiptStartsWithInitAndEndsWithCut() {
        let bytes = [UInt8](TestReceipt.build(model: .tmT88V80mm))
        #expect(Array(bytes.prefix(2)) == [0x1B, 0x40])
        #expect(Array(bytes.suffix(4)) == [0x1D, 0x56, 66, 0])
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("TM-T88V COMPATIBILITY TEST"))
        #expect(text.contains("Native Apple Silicon printing works."))
    }

    @Test func testReceiptWithoutCutHasNoGsV() {
        var model = PrinterModel.tmT88V80mm
        model.cutMode = .none
        let bytes = [UInt8](TestReceipt.build(model: model))
        #expect(!zip(bytes, bytes.dropFirst()).contains { $0 == 0x1D && $1 == 0x56 })
    }
}
