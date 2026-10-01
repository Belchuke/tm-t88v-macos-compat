import Foundation

public enum EscPosAlignment: UInt8, Sendable {
    case left = 0
    case center = 1
    case right = 2
}

public final class EscPosEncoder {
    public private(set) var data = Data()

    public init() {}

    @discardableResult
    public func initialize() -> Self {
        append(0x1B, 0x40)
    }

    @discardableResult
    public func align(_ alignment: EscPosAlignment) -> Self {
        append(0x1B, 0x61, alignment.rawValue)
    }

    @discardableResult
    public func bold(_ enabled: Bool) -> Self {
        append(0x1B, 0x45, enabled ? 1 : 0)
    }

    @discardableResult
    public func characterSize(width: Int, height: Int) -> Self {
        let w = UInt8(clamping: max(1, min(8, width)) - 1)
        let h = UInt8(clamping: max(1, min(8, height)) - 1)
        return append(0x1D, 0x21, w << 4 | h)
    }

    @discardableResult
    public func text(_ string: String) -> Self {
        data.append(contentsOf: Self.asciiBytes(string))
        return self
    }

    @discardableResult
    public func line(_ string: String = "") -> Self {
        text(string)
        return append(0x0A)
    }

    @discardableResult
    public func feed(lines: Int) -> Self {
        var remaining = max(0, lines)
        while remaining > 0 {
            let n = min(remaining, 255)
            append(0x1B, 0x64, UInt8(n))
            remaining -= n
        }
        return self
    }

    @discardableResult
    public func cut(_ mode: CutMode, feedUnits: Int = 0) -> Self {
        let n = UInt8(clamping: max(0, feedUnits))
        switch mode {
        case .none: return self
        case .full: return append(0x1D, 0x56, 65, n)
        case .partial: return append(0x1D, 0x56, 66, n)
        }
    }

    @discardableResult
    public func raw(_ bytes: [UInt8]) -> Self {
        data.append(contentsOf: bytes)
        return self
    }

    static func asciiBytes(_ string: String) -> [UInt8] {
        string.unicodeScalars.map { scalar in
            if scalar == "\n" || (scalar.value >= 0x20 && scalar.value < 0x7F) {
                return UInt8(scalar.value)
            }
            return UInt8(ascii: "?")
        }
    }

    @discardableResult
    private func append(_ bytes: UInt8...) -> Self {
        data.append(contentsOf: bytes)
        return self
    }
}
