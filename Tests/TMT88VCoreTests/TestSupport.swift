import Foundation
@testable import TMT88VCore

final class CapturingOutput: PrintOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPayloads: [Data] = []
    var failure: Error?
    var connectionName: String { "test" }

    var payloads: [Data] { lock.withLock { storedPayloads } }

    func send(_ payload: Data, jobID: Int) throws -> OutputReceipt {
        if let failure { throw failure }
        lock.withLock { storedPayloads.append(payload) }
        return OutputReceipt(connection: "test", transferMilliseconds: 0)
    }
}

enum Fixture {
    static func be32(_ value: Int) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func urf(width: Int, height: Int, dpi: Int = 180, pages: Int = 1, pixel: (Int, Int) -> UInt8) -> Data {
        var data = Data("UNIRAST\0".utf8)
        data.append(contentsOf: be32(pages))
        for _ in 0..<pages {
            var header = [UInt8](repeating: 0, count: 32)
            header[0] = 8
            header.replaceSubrange(12..<16, with: be32(width))
            header.replaceSubrange(16..<20, with: be32(height))
            header.replaceSubrange(20..<24, with: be32(dpi))
            data.append(contentsOf: header)
            for y in 0..<height {
                data.append(0)
                for x in 0..<width { data.append(contentsOf: [0, pixel(x, y)]) }
            }
        }
        return data
    }

    static func pwgHeader(width: Int, height: Int, bitsPerPixel: Int, colorSpace: Int, dpi: Int = 180) -> Data {
        var header = [UInt8](repeating: 0, count: 1796)
        func put(_ offset: Int, _ value: Int) { header.replaceSubrange(offset..<(offset + 4), with: be32(value)) }
        put(276, dpi); put(280, dpi)
        put(372, width); put(376, height)
        put(384, bitsPerPixel == 24 ? 8 : bitsPerPixel); put(388, bitsPerPixel)
        put(392, (width * bitsPerPixel + 7) / 8); put(400, colorSpace)
        return Data(header)
    }

    static func pwgGray(width: Int, height: Int, pixel: (Int, Int) -> UInt8) -> Data {
        var data = Data("RaS2".utf8)
        data.append(pwgHeader(width: width, height: height, bitsPerPixel: 8, colorSpace: 18))
        for y in 0..<height {
            data.append(0)
            for x in 0..<width { data.append(contentsOf: [0, pixel(x, y)]) }
        }
        return data
    }

    static func ippRequest(
        _ operation: UInt16,
        id: UInt32 = 1,
        printerURI: String? = "ipp://127.0.0.1:8632/ipp/print",
        extra: [IppAttribute] = [],
        document: Data = Data()
    ) -> Data {
        var attributes = [
            IppAttribute("attributes-charset", .charset("utf-8")),
            IppAttribute("attributes-natural-language", .naturalLanguage("en")),
        ]
        if let printerURI { attributes.append(IppAttribute("printer-uri", .uri(printerURI))) }
        attributes += extra
        var data = IppCodec.encode(IppMessage(code: operation, requestID: id, groups: [IppGroup(tag: IppTag.operationGroup, attributes: attributes)]))
        data.append(document)
        return data
    }

    static func decodeResponse(_ data: Data) throws -> IppMessage {
        try IppCodec.decode(data).message
    }
}

func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
