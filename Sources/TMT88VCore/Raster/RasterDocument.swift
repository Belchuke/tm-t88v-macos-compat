import Foundation

public enum RasterDocumentError: Error, CustomStringConvertible, Equatable {
    case unrecognizedFormat
    case truncated(String)
    case unsupported(String)
    case tooLarge(String)

    public var description: String {
        switch self {
        case .unrecognizedFormat: "unrecognized_raster_format"
        case .truncated(let what): "truncated_raster: \(what)"
        case .unsupported(let what): "unsupported_raster: \(what)"
        case .tooLarge(let what): "raster_too_large: \(what)"
        }
    }
}

public enum RasterFormat: String, Sendable {
    case urf = "image/urf"
    case pwg = "image/pwg-raster"

    public static func detect(_ data: Data) -> RasterFormat? {
        if data.starts(with: Array("UNIRAST\0".utf8)) { return .urf }
        if data.starts(with: Array("RaS2".utf8)) { return .pwg }
        return nil
    }
}

public struct RasterPage: Sendable {
    public let image: GrayImage
    public let dpiX: Int
    public let dpiY: Int
}

public enum RasterDocument {
    public static let maxPixelsPerPage = 48_000_000
    public static let maxPages = 200

    public static func parse(_ data: Data) throws -> [RasterPage] {
        switch RasterFormat.detect(data) {
        case .urf: try parseURF(data)
        case .pwg: try parsePWG(data)
        case nil: throw RasterDocumentError.unrecognizedFormat
        }
    }

    static func parseURF(_ data: Data) throws -> [RasterPage] {
        var cursor = Cursor(data)
        try cursor.skip(8)
        let pageCount = Int(try cursor.u32())
        guard pageCount <= maxPages else { throw RasterDocumentError.tooLarge("\(pageCount) pages") }

        var pages: [RasterPage] = []
        for index in 0..<pageCount {
            let header = try cursor.take(32, "page \(index) header")
            let bitsPerPixel = Int(header[0])
            let colorSpace = Int(header[1])
            let width = Int(be32(header, 12))
            let height = Int(be32(header, 16))
            let dpi = Int(be32(header, 20))
            let format: PixelFormat
            switch (bitsPerPixel, colorSpace) {
            case (8, 0), (8, 4): format = .gray8
            case (24, 1), (24, 3), (24, 5): format = .rgb24
            default: throw RasterDocumentError.unsupported("URF \(bitsPerPixel) bpp colorspace \(colorSpace)")
            }
            let image = try decodePackBits(
                cursor: &cursor, width: width, height: height,
                bytesPerPixel: bitsPerPixel / 8, bytesPerLine: width * bitsPerPixel / 8, whiteByte: 0xFF, format: format
            )
            pages.append(RasterPage(image: image, dpiX: dpi, dpiY: dpi))
        }
        return pages
    }

    static func parsePWG(_ data: Data) throws -> [RasterPage] {
        var cursor = Cursor(data)
        try cursor.skip(4)
        var pages: [RasterPage] = []
        while cursor.remaining > 0 {
            guard pages.count < maxPages else { throw RasterDocumentError.tooLarge("more than \(maxPages) pages") }
            let header = try cursor.take(1796, "page \(pages.count) header")
            let dpiX = Int(be32(header, 276))
            let dpiY = Int(be32(header, 280))
            let width = Int(be32(header, 372))
            let height = Int(be32(header, 376))
            let bitsPerColor = Int(be32(header, 384))
            let bitsPerPixel = Int(be32(header, 388))
            let bytesPerLine = Int(be32(header, 392))
            let colorSpace = Int(be32(header, 400))

            let format: PixelFormat
            switch (bitsPerPixel, bitsPerColor, colorSpace) {
            case (8, 8, 0), (8, 8, 18): format = .gray8
            case (8, 8, 3): format = .black8
            case (1, 1, 3): format = .black1
            case (1, 1, 0), (1, 1, 18): format = .white1
            case (24, 8, 1), (24, 8, 19), (24, 8, 20): format = .rgb24
            default: throw RasterDocumentError.unsupported("PWG \(bitsPerPixel) bpp, \(bitsPerColor) bits/color, colorspace \(colorSpace)")
            }
            guard width > 0, width <= 1_000_000, bytesPerLine <= (width * bitsPerPixel + 7) / 8 + 64 else {
                throw RasterDocumentError.unsupported("bytesPerLine \(bytesPerLine) for width \(width)")
            }
            guard bytesPerLine >= (width * bitsPerPixel + 7) / 8 else {
                throw RasterDocumentError.unsupported("bytesPerLine \(bytesPerLine) too small for width \(width)")
            }
            let whiteByte: UInt8 = (format == .black1 || format == .black8) ? 0x00 : 0xFF
            let image = try decodePackBits(
                cursor: &cursor, width: width, height: height,
                bytesPerPixel: max(1, bitsPerPixel / 8), bytesPerLine: bytesPerLine, whiteByte: whiteByte, format: format
            )
            pages.append(RasterPage(image: image, dpiX: dpiX, dpiY: dpiY))
        }
        guard !pages.isEmpty else { throw RasterDocumentError.truncated("no pages") }
        return pages
    }

    private enum PixelFormat {
        case gray8, black8, white1, black1, rgb24
    }

    private static func decodePackBits(
        cursor: inout Cursor, width: Int, height: Int,
        bytesPerPixel: Int, bytesPerLine: Int, whiteByte: UInt8, format: PixelFormat
    ) throws -> GrayImage {
        guard width > 0, height > 0 else { throw RasterDocumentError.unsupported("empty page \(width)x\(height)") }
        guard width * height <= maxPixelsPerPage else { throw RasterDocumentError.tooLarge("\(width)x\(height) pixels") }

        var pixels = [UInt8](repeating: 255, count: width * height)
        var line = [UInt8](repeating: 0, count: bytesPerLine)
        var row = 0
        while row < height {
            let repeatCount = Int(try cursor.u8()) + 1
            var filled = 0
            while filled < bytesPerLine {
                let code = try cursor.u8()
                if code == 0x80 {
                    for i in filled..<bytesPerLine { line[i] = whiteByte }
                    filled = bytesPerLine
                } else if code < 0x80 {
                    let unit = try cursor.take(bytesPerPixel, "run pixel")
                    let count = (Int(code) + 1) * bytesPerPixel
                    guard filled + count <= bytesPerLine else { throw RasterDocumentError.truncated("run overflows line") }
                    for i in 0..<count { line[filled + i] = unit[unit.startIndex + i % bytesPerPixel] }
                    filled += count
                } else {
                    let count = (257 - Int(code)) * bytesPerPixel
                    guard filled + count <= bytesPerLine else { throw RasterDocumentError.truncated("literal overflows line") }
                    let literal = try cursor.take(count, "literal pixels")
                    for i in 0..<count { line[filled + i] = literal[literal.startIndex + i] }
                    filled += count
                }
            }

            let converted = convert(line, width: width, format: format)
            let rows = min(repeatCount, height - row)
            for r in 0..<rows {
                pixels.replaceSubrange(((row + r) * width)..<((row + r + 1) * width), with: converted)
            }
            row += rows
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    private static func convert(_ line: [UInt8], width: Int, format: PixelFormat) -> [UInt8] {
        switch format {
        case .gray8: return Array(line[0..<width])
        case .black8: return line[0..<width].map { 255 - $0 }
        case .rgb24:
            return (0..<width).map { x in
                let r = Int(line[x * 3]), g = Int(line[x * 3 + 1]), b = Int(line[x * 3 + 2])
                return UInt8((r * 299 + g * 587 + b * 114) / 1000)
            }
        case .white1, .black1:
            return (0..<width).map { x in
                let bit = line[x / 8] & (0x80 >> UInt8(x % 8)) != 0
                return bit == (format == .white1) ? 255 : 0
            }
        }
    }

    private static func be32(_ bytes: Data, _ offset: Int) -> UInt32 {
        let base = bytes.startIndex + offset
        return UInt32(bytes[base]) << 24 | UInt32(bytes[base + 1]) << 16 | UInt32(bytes[base + 2]) << 8 | UInt32(bytes[base + 3])
    }

    private struct Cursor {
        let data: Data
        var offset = 0

        init(_ data: Data) { self.data = data }

        var remaining: Int { data.count - offset }

        mutating func skip(_ count: Int) throws { _ = try take(count, "header") }

        mutating func take(_ count: Int, _ what: String) throws -> Data {
            guard count >= 0, offset + count <= data.count else { throw RasterDocumentError.truncated(what) }
            defer { offset += count }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
        }

        mutating func u8() throws -> UInt8 {
            guard offset < data.count else { throw RasterDocumentError.truncated("pixel data") }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        mutating func u32() throws -> UInt32 {
            let d = try take(4, "u32")
            return UInt32(d[d.startIndex]) << 24 | UInt32(d[d.startIndex + 1]) << 16 | UInt32(d[d.startIndex + 2]) << 8 | UInt32(d[d.startIndex + 3])
        }
    }
}

extension GrayImage {
    public func trimmingTrailingWhite(tolerance: UInt8 = 250) -> GrayImage? {
        var lastInk = -1
        outer: for y in stride(from: height - 1, through: 0, by: -1) {
            for x in 0..<width where pixels[y * width + x] < tolerance {
                lastInk = y
                break outer
            }
        }
        guard lastInk >= 0 else { return nil }
        return GrayImage(width: width, height: lastInk + 1, pixels: Array(pixels[0..<((lastInk + 1) * width)]))
    }
}
