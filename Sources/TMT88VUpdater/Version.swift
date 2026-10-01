import Foundation

public struct Version: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Strict MAJOR.MINOR.PATCH: ASCII digits only, no leading zeros, at most 9 digits per part, no whitespace,
    /// no prefix ("v1.2.3"), no pre-release or build suffix.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            guard part == "0" || part.first != "0" else { return nil }
            guard let value = Int(part) else { return nil }
            numbers.append(value)
        }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
