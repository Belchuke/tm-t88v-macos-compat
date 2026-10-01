import Foundation

public struct DecodedReceipt: Equatable {
    public var bitmap: MonoBitmap
    public var feedLines: Int
    public var cut: Bool
}

public enum EscPosDecodeError: Error, Equatable {
    case unexpectedByte(UInt8, offset: Int)
    case truncated(offset: Int)
    case inconsistentWidth(offset: Int)
}

public enum EscPosRasterDecoder {
    public static func decode(_ data: Data) throws -> [DecodedReceipt] {
        let bytes = [UInt8](data)
        var receipts: [DecodedReceipt] = []
        var width = 0
        var rowBytes = 0
        var rows: [UInt8] = []
        var feed = 0
        var i = 0

        func flush(cut: Bool) {
            guard rowBytes > 0, !rows.isEmpty else { return }
            receipts.append(DecodedReceipt(bitmap: MonoBitmap(width: width, height: rows.count / rowBytes, data: rows), feedLines: feed, cut: cut))
            rows = []
            feed = 0
        }

        while i < bytes.count {
            guard i + 1 < bytes.count else { throw EscPosDecodeError.truncated(offset: i) }
            switch (bytes[i], bytes[i + 1]) {
            case (0x1B, 0x40): i += 2
            case (0x1B, 0x61): i += 3
            case (0x1B, 0x64):
                guard i + 2 < bytes.count else { throw EscPosDecodeError.truncated(offset: i) }
                feed += Int(bytes[i + 2])
                i += 3
            case (0x1D, 0x56):
                guard i + 3 < bytes.count else { throw EscPosDecodeError.truncated(offset: i) }
                flush(cut: true)
                i += 4
            case (0x1D, 0x76):
                guard i + 7 < bytes.count, bytes[i + 2] == 0x30 else { throw EscPosDecodeError.truncated(offset: i) }
                let bandRowBytes = Int(bytes[i + 4]) | Int(bytes[i + 5]) << 8
                let bandRows = Int(bytes[i + 6]) | Int(bytes[i + 7]) << 8
                let count = bandRowBytes * bandRows
                guard i + 8 + count <= bytes.count else { throw EscPosDecodeError.truncated(offset: i) }
                if rowBytes != 0, rowBytes != bandRowBytes, !rows.isEmpty { throw EscPosDecodeError.inconsistentWidth(offset: i) }
                rowBytes = bandRowBytes
                width = bandRowBytes * 8
                rows.append(contentsOf: bytes[(i + 8)..<(i + 8 + count)])
                i += 8 + count
            default:
                throw EscPosDecodeError.unexpectedByte(bytes[i], offset: i)
            }
        }
        flush(cut: false)
        return receipts
    }
}
