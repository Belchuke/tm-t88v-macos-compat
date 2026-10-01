import Foundation
import Testing
@testable import TMT88VCore

struct IppCodecTests {
    @Test func roundTripsEveryValueKind() throws {
        let message = IppMessage(code: 0x000B, requestID: 7, groups: [
            IppGroup(tag: IppTag.operationGroup, attributes: [
                IppAttribute("attributes-charset", .charset("utf-8")),
                IppAttribute("attributes-natural-language", .naturalLanguage("en")),
                IppAttribute("printer-uri", .uri("ipp://127.0.0.1:8632/ipp/print")),
                IppAttribute("requested-attributes", [.keyword("a"), .keyword("b"), .keyword("c")]),
            ]),
            IppGroup(tag: IppTag.printerGroup, attributes: [
                IppAttribute("n", .integer(-5)),
                IppAttribute("e", .enumeration(4)),
                IppAttribute("b", .boolean(true)),
                IppAttribute("t", .text("hello æøå")),
                IppAttribute("nm", .name("name")),
                IppAttribute("mt", .mimeMediaType("image/urf")),
                IppAttribute("r", .resolution(cross: 180, feed: 180, units: 3)),
                IppAttribute("range", .range(1, 99)),
                IppAttribute("oct", .octets(Data([1, 2, 3]))),
                IppAttribute("empty", []),
            ]),
        ])
        var expected = message
        expected.groups[1].attributes[9] = IppAttribute("empty", .outOfBand(IppTag.noValue))

        let decoded = try IppCodec.decode(IppCodec.encode(message))
        #expect(decoded.message == expected)
        #expect(decoded.bodyOffset == IppCodec.encode(message).count)
    }

    @Test func roundTripsNestedCollectionsAndMultiValueMembers() throws {
        let inner = IppValue.collection([
            IppAttribute("x-dimension", .integer(7200)),
            IppAttribute("y-dimension", .range(2540, 200_000)),
        ])
        let message = IppMessage(code: 0, requestID: 1, groups: [IppGroup(tag: IppTag.printerGroup, attributes: [
            IppAttribute("media-col-database", [
                .collection([
                    IppAttribute("media-size", inner),
                    IppAttribute("media-margins", [.integer(0), .integer(1)]),
                    IppAttribute("media-type", .keyword("continuous")),
                ]),
                .collection([IppAttribute("media-size", inner)]),
            ]),
        ])])
        let decoded = try IppCodec.decode(IppCodec.encode(message)).message
        #expect(decoded == message)
    }

    @Test func bodyOffsetPointsAtDocumentData() throws {
        var data = IppCodec.encode(IppMessage(code: 2, requestID: 1, groups: [IppGroup(tag: IppTag.operationGroup, attributes: [IppAttribute("a", .integer(1))])]))
        let offset = data.count
        data.append(Data("UNIRAST\0".utf8))
        #expect(try IppCodec.decode(data).bodyOffset == offset)
    }

    @Test func rejectsTruncatedMessagesAtEveryLength() {
        let full = Fixture.ippRequest(IppOperation.getPrinterAttributes, extra: [IppAttribute("requested-attributes", .keyword("all"))])
        for length in 0..<(full.count - 1) {
            #expect(throws: IppParseError.self) { try IppCodec.decode(full.prefix(length)) }
        }
        #expect(throws: Never.self) { try IppCodec.decode(full) }
    }

    @Test func rejectsAttributeBeforeAnyGroup() {
        var bad = Data([2, 0, 0, 0xB, 0, 0, 0, 1])
        bad.append(contentsOf: [IppTag.integer, 0, 1, 0x61, 0, 4, 0, 0, 0, 1, IppTag.end])
        #expect(throws: IppParseError.malformed("attribute before group")) { try IppCodec.decode(bad) }
    }

    @Test func rejectsWrongFixedLengths() {
        for (tag, length) in [(IppTag.integer, 3), (IppTag.boolean, 2), (IppTag.resolution, 8), (IppTag.rangeOfInteger, 4)] as [(UInt8, UInt16)] {
            var bad = Data([2, 0, 0, 0xB, 0, 0, 0, 1, IppTag.operationGroup, tag, 0, 1, 0x61])
            bad.appendBE(length)
            bad.append(contentsOf: [UInt8](repeating: 0, count: Int(length)))
            bad.append(IppTag.end)
            #expect(throws: IppParseError.self) { try IppCodec.decode(bad) }
        }
    }

    @Test func rejectsAdditionalValueWithoutAttribute() {
        let bad = Data([2, 0, 0, 0xB, 0, 0, 0, 1, IppTag.operationGroup, IppTag.integer, 0, 0, 0, 4, 0, 0, 0, 1, IppTag.end])
        #expect(throws: IppParseError.malformed("additional value without attribute")) { try IppCodec.decode(bad) }
    }

    @Test func rejectsUnterminatedCollection() {
        let bad = Data([2, 0, 0, 0xB, 0, 0, 0, 1, IppTag.printerGroup, IppTag.beginCollection, 0, 1, 0x61, 0, 0])
        #expect(throws: IppParseError.self) { try IppCodec.decode(bad) }
    }

    @Test func rejectsValueLengthLargerThanMessage() {
        let bad = Data([2, 0, 0, 0xB, 0, 0, 0, 1, IppTag.operationGroup, IppTag.keyword, 0, 1, 0x61, 0xFF, 0xFF, 0x41, IppTag.end])
        #expect(throws: IppParseError.truncated) { try IppCodec.decode(bad) }
    }

    @Test func randomGarbageNeverCrashes() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let length = Int.random(in: 0..<200, using: &generator)
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            _ = try? IppCodec.decode(data)
        }
    }

    @Test func mutatedValidRequestsNeverCrash() {
        let valid = [UInt8](Fixture.ippRequest(IppOperation.printJob, extra: [IppAttribute("job-name", .name("x"))]))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            var mutated = valid
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                mutated[Int.random(in: 0..<mutated.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = try? IppCodec.decode(Data(mutated))
        }
    }
}
