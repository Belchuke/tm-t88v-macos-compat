import Foundation

public struct PendingInstall: Codable, Equatable, Sendable {
    public var version: String
    public var startedAt: Date

    public init(version: String, startedAt: Date) {
        self.version = version
        self.startedAt = startedAt
    }
}

public struct UpdaterState: Codable, Equatable, Sendable {
    public var lastCheckAt: Date?
    public var nextCheckAt: Date?
    public var lastSuccessfulUpdateAt: Date?
    public var lastSeenVersion: String?
    public var pendingInstall: PendingInstall?

    public init() {}
}

public struct StateStore {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// A missing or corrupt file yields an empty state (never an error); the reason is returned for logging.
    public func load(fileManager: FileManager = .default) -> (state: UpdaterState, problem: String?) {
        guard fileManager.fileExists(atPath: path) else { return (UpdaterState(), nil) }
        guard let data = fileManager.contents(atPath: path), data.count <= 64 * 1024 else {
            return (UpdaterState(), "state file unreadable or too large; starting from an empty state")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(UpdaterState.self, from: data) else {
            return (UpdaterState(), "state file is corrupt; starting from an empty state")
        }
        return (state, nil)
    }

    /// Atomic: write a private temporary file in the same directory, then rename over the target.
    public func save(_ state: UpdaterState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(state)
        let temporary = path + ".tmp.\(getpid())"
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o644]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary, path) != 0 {
            unlink(temporary)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
