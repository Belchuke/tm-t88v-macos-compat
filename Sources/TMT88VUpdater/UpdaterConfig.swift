import Foundation

public enum UpdateSetting: Equatable, Sendable {
    case enabled(fromFile: Bool)
    case disabled(reason: String)

    public var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }
}

public enum UpdaterConfig {
    public static let defaultContents = "{\n  \"automaticUpdates\": true\n}\n"

    /// Missing file: the documented default (enabled). Anything that is present but not exactly a JSON object with a
    /// boolean `automaticUpdates` fails safe: disabled.
    public static func load(path: String, fileManager: FileManager = .default) -> UpdateSetting {
        guard fileManager.fileExists(atPath: path) else { return .enabled(fromFile: false) }
        guard let data = fileManager.contents(atPath: path), data.count <= 64 * 1024 else {
            return .disabled(reason: "config.json is unreadable or larger than 64 KB")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else {
            return .disabled(reason: "config.json is not a valid JSON object")
        }
        guard let value = dictionary["automaticUpdates"] else {
            return .disabled(reason: "config.json has no automaticUpdates key")
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return .disabled(reason: "automaticUpdates is not a boolean")
        }
        return number.boolValue ? .enabled(fromFile: true) : .disabled(reason: "automaticUpdates is false")
    }
}
