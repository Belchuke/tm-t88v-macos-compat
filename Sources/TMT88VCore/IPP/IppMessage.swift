import Foundation

public enum IppTag {
    static let operationGroup: UInt8 = 0x01
    static let jobGroup: UInt8 = 0x02
    static let end: UInt8 = 0x03
    static let printerGroup: UInt8 = 0x04
    static let unsupportedGroup: UInt8 = 0x05

    static let unsupported: UInt8 = 0x10
    static let unknown: UInt8 = 0x12
    static let noValue: UInt8 = 0x13
    static let integer: UInt8 = 0x21
    static let boolean: UInt8 = 0x22
    static let enumeration: UInt8 = 0x23
    static let octetString: UInt8 = 0x30
    static let dateTime: UInt8 = 0x31
    static let resolution: UInt8 = 0x32
    static let rangeOfInteger: UInt8 = 0x33
    static let beginCollection: UInt8 = 0x34
    static let textWithLanguage: UInt8 = 0x35
    static let nameWithLanguage: UInt8 = 0x36
    static let endCollection: UInt8 = 0x37
    static let text: UInt8 = 0x41
    static let name: UInt8 = 0x42
    static let keyword: UInt8 = 0x44
    static let uri: UInt8 = 0x45
    static let uriScheme: UInt8 = 0x46
    static let charset: UInt8 = 0x47
    static let naturalLanguage: UInt8 = 0x48
    static let mimeMediaType: UInt8 = 0x49
    static let memberName: UInt8 = 0x4A
}

public enum IppValue: Equatable, Sendable {
    case integer(Int32)
    case boolean(Bool)
    case enumeration(Int32)
    case text(String)
    case name(String)
    case keyword(String)
    case uri(String)
    case uriScheme(String)
    case charset(String)
    case naturalLanguage(String)
    case mimeMediaType(String)
    case octets(Data)
    case dateTime(Data)
    case resolution(cross: Int32, feed: Int32, units: UInt8)
    case range(Int32, Int32)
    case collection([IppAttribute])
    case outOfBand(UInt8)
    case other(tag: UInt8, Data)

    public var string: String? {
        switch self {
        case .text(let s), .name(let s), .keyword(let s), .uri(let s), .uriScheme(let s),
             .charset(let s), .naturalLanguage(let s), .mimeMediaType(let s): s
        default: nil
        }
    }

    public var int: Int32? {
        switch self {
        case .integer(let v), .enumeration(let v): v
        default: nil
        }
    }
}

public struct IppAttribute: Equatable, Sendable {
    public var name: String
    public var values: [IppValue]

    public init(_ name: String, _ values: [IppValue]) {
        self.name = name
        self.values = values
    }

    public init(_ name: String, _ value: IppValue) {
        self.init(name, [value])
    }
}

public struct IppGroup: Equatable, Sendable {
    public var tag: UInt8
    public var attributes: [IppAttribute]

    public init(tag: UInt8, attributes: [IppAttribute] = []) {
        self.tag = tag
        self.attributes = attributes
    }

    public subscript(name: String) -> IppAttribute? {
        attributes.first { $0.name == name }
    }
}

public struct IppMessage: Equatable, Sendable {
    public var versionMajor: UInt8 = 2
    public var versionMinor: UInt8 = 0
    public var code: UInt16
    public var requestID: UInt32
    public var groups: [IppGroup] = []

    public init(code: UInt16, requestID: UInt32, groups: [IppGroup] = []) {
        self.code = code
        self.requestID = requestID
        self.groups = groups
    }

    public func group(_ tag: UInt8) -> IppGroup? {
        groups.first { $0.tag == tag }
    }
}

public enum IppParseError: Error, Equatable {
    case truncated
    case malformed(String)
}

public enum IppCodec {
    public static func decode(_ data: Data) throws -> (message: IppMessage, bodyOffset: Int) {
        var reader = Reader(bytes: data)
        let major = try reader.u8()
        let minor = try reader.u8()
        var message = IppMessage(code: try reader.u16(), requestID: try reader.u32())
        message.versionMajor = major
        message.versionMinor = minor

        var current: IppGroup?
        while true {
            let tag = try reader.u8()
            if tag == IppTag.end { break }
            if tag < 0x10 {
                if let current { message.groups.append(current) }
                current = IppGroup(tag: tag)
                continue
            }
            guard current != nil else { throw IppParseError.malformed("attribute before group") }
            let nameLength = Int(try reader.u16())
            let name = try reader.string(nameLength)
            let value = try readValue(tag: tag, reader: &reader)
            if nameLength == 0 {
                guard var last = current!.attributes.popLast() else { throw IppParseError.malformed("additional value without attribute") }
                last.values.append(value)
                current!.attributes.append(last)
            } else {
                current!.attributes.append(IppAttribute(name, value))
            }
        }
        if let current { message.groups.append(current) }
        return (message, reader.offset)
    }

    private static func readValue(tag: UInt8, reader: inout Reader) throws -> IppValue {
        if tag == IppTag.beginCollection {
            _ = try reader.bytes(Int(try reader.u16()))
            return .collection(try readCollection(reader: &reader))
        }
        let length = Int(try reader.u16())
        let raw = try reader.bytes(length)
        switch tag {
        case IppTag.integer, IppTag.enumeration:
            guard length == 4 else { throw IppParseError.malformed("integer length \(length)") }
            let v = Int32(bitPattern: raw.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            return tag == IppTag.integer ? .integer(v) : .enumeration(v)
        case IppTag.boolean:
            guard length == 1 else { throw IppParseError.malformed("boolean length \(length)") }
            return .boolean(raw[raw.startIndex] != 0)
        case IppTag.resolution:
            guard length == 9 else { throw IppParseError.malformed("resolution length \(length)") }
            let b = [UInt8](raw)
            let cross = Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
            let feed = Int32(bitPattern: UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7]))
            return .resolution(cross: cross, feed: feed, units: b[8])
        case IppTag.rangeOfInteger:
            guard length == 8 else { throw IppParseError.malformed("range length \(length)") }
            let b = [UInt8](raw)
            let lo = Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
            let hi = Int32(bitPattern: UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7]))
            return .range(lo, hi)
        case IppTag.text: return .text(String(decoding: raw, as: UTF8.self))
        case IppTag.name: return .name(String(decoding: raw, as: UTF8.self))
        case IppTag.keyword: return .keyword(String(decoding: raw, as: UTF8.self))
        case IppTag.uri: return .uri(String(decoding: raw, as: UTF8.self))
        case IppTag.uriScheme: return .uriScheme(String(decoding: raw, as: UTF8.self))
        case IppTag.charset: return .charset(String(decoding: raw, as: UTF8.self))
        case IppTag.naturalLanguage: return .naturalLanguage(String(decoding: raw, as: UTF8.self))
        case IppTag.mimeMediaType: return .mimeMediaType(String(decoding: raw, as: UTF8.self))
        case IppTag.octetString: return .octets(Data(raw))
        case IppTag.dateTime: return .dateTime(Data(raw))
        case 0x10...0x1F: return .outOfBand(tag)
        default: return .other(tag: tag, Data(raw))
        }
    }

    private static func readCollection(reader: inout Reader) throws -> [IppAttribute] {
        var members: [IppAttribute] = []
        while true {
            let tag = try reader.u8()
            let nameLength = Int(try reader.u16())
            _ = try reader.bytes(nameLength)
            switch tag {
            case IppTag.endCollection:
                _ = try reader.bytes(Int(try reader.u16()))
                return members
            case IppTag.memberName:
                let memberName = try reader.string(Int(try reader.u16()))
                members.append(IppAttribute(memberName, []))
            default:
                guard !members.isEmpty else { throw IppParseError.malformed("collection value before member name") }
                let value: IppValue
                if tag == IppTag.beginCollection {
                    _ = try reader.bytes(Int(try reader.u16()))
                    value = .collection(try readCollection(reader: &reader))
                } else {
                    value = try readValue(tag: tag, reader: &reader)
                }
                members[members.count - 1].values.append(value)
            }
        }
    }

    public static func encode(_ message: IppMessage) -> Data {
        var out = Data()
        out.append(message.versionMajor)
        out.append(message.versionMinor)
        out.appendBE(message.code)
        out.appendBE(message.requestID)
        for group in message.groups {
            out.append(group.tag)
            for attribute in group.attributes {
                for (index, value) in attribute.values.enumerated() {
                    write(value, name: index == 0 ? attribute.name : "", into: &out)
                }
                if attribute.values.isEmpty {
                    write(.outOfBand(IppTag.noValue), name: attribute.name, into: &out)
                }
            }
        }
        out.append(IppTag.end)
        return out
    }

    private static func write(_ value: IppValue, name: String, into out: inout Data) {
        func header(_ tag: UInt8, _ name: String) {
            out.append(tag)
            let bytes = Array(name.utf8)
            out.appendBE(UInt16(bytes.count))
            out.append(contentsOf: bytes)
        }
        func string(_ tag: UInt8, _ s: String) {
            header(tag, name)
            let bytes = Array(s.utf8)
            out.appendBE(UInt16(min(bytes.count, 65535)))
            out.append(contentsOf: bytes.prefix(65535))
        }
        switch value {
        case .integer(let v): header(IppTag.integer, name); out.appendBE(UInt16(4)); out.appendBE(UInt32(bitPattern: v))
        case .enumeration(let v): header(IppTag.enumeration, name); out.appendBE(UInt16(4)); out.appendBE(UInt32(bitPattern: v))
        case .boolean(let v): header(IppTag.boolean, name); out.appendBE(UInt16(1)); out.append(v ? 1 : 0)
        case .text(let s): string(IppTag.text, s)
        case .name(let s): string(IppTag.name, s)
        case .keyword(let s): string(IppTag.keyword, s)
        case .uri(let s): string(IppTag.uri, s)
        case .uriScheme(let s): string(IppTag.uriScheme, s)
        case .charset(let s): string(IppTag.charset, s)
        case .naturalLanguage(let s): string(IppTag.naturalLanguage, s)
        case .mimeMediaType(let s): string(IppTag.mimeMediaType, s)
        case .octets(let d): header(IppTag.octetString, name); out.appendBE(UInt16(d.count)); out.append(d)
        case .dateTime(let d): header(IppTag.dateTime, name); out.appendBE(UInt16(d.count)); out.append(d)
        case .resolution(let cross, let feed, let units):
            header(IppTag.resolution, name); out.appendBE(UInt16(9))
            out.appendBE(UInt32(bitPattern: cross)); out.appendBE(UInt32(bitPattern: feed)); out.append(units)
        case .range(let lo, let hi):
            header(IppTag.rangeOfInteger, name); out.appendBE(UInt16(8))
            out.appendBE(UInt32(bitPattern: lo)); out.appendBE(UInt32(bitPattern: hi))
        case .collection(let members):
            header(IppTag.beginCollection, name); out.appendBE(UInt16(0))
            for member in members {
                for (index, memberValue) in member.values.enumerated() {
                    if index == 0 {
                        header(IppTag.memberName, "")
                        let nameBytes = Array(member.name.utf8)
                        out.appendBE(UInt16(nameBytes.count))
                        out.append(contentsOf: nameBytes)
                    }
                    write(memberValue, name: "", into: &out)
                }
            }
            header(IppTag.endCollection, ""); out.appendBE(UInt16(0))
        case .outOfBand(let tag): header(tag, name); out.appendBE(UInt16(0))
        case .other(let tag, let d): header(tag, name); out.appendBE(UInt16(d.count)); out.append(d)
        }
    }

    private struct Reader {
        let bytes: Data
        var offset = 0

        init(bytes: Data) { self.bytes = bytes }

        mutating func u8() throws -> UInt8 {
            guard offset < bytes.count else { throw IppParseError.truncated }
            defer { offset += 1 }
            return bytes[bytes.startIndex + offset]
        }

        mutating func u16() throws -> UInt16 {
            UInt16(try u8()) << 8 | UInt16(try u8())
        }

        mutating func u32() throws -> UInt32 {
            UInt32(try u16()) << 16 | UInt32(try u16())
        }

        mutating func bytes(_ count: Int) throws -> Data.SubSequence {
            guard count >= 0, offset + count <= bytes.count else { throw IppParseError.truncated }
            defer { offset += count }
            return bytes[(bytes.startIndex + offset)..<(bytes.startIndex + offset + count)]
        }

        mutating func string(_ count: Int) throws -> String {
            String(decoding: try bytes(count), as: UTF8.self)
        }
    }
}

extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8(value >> 8)); append(UInt8(value & 0xFF))
    }

    mutating func appendBE(_ value: UInt32) {
        appendBE(UInt16(value >> 16)); appendBE(UInt16(value & 0xFFFF))
    }
}
