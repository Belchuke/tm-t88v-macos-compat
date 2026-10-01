import Foundation

public struct InstalledVersionReader {
    public let runner: CommandRunning
    public let identifier: String

    public init(runner: CommandRunning, identifier: String = UpdaterConstants.packageIdentifier) {
        self.runner = runner
        self.identifier = identifier
    }

    /// The installed version is the macOS package receipt (`pkgutil --pkg-info-plist`), never anything read from GitHub.
    public func read() -> Version? {
        let result = runner.run("/usr/sbin/pkgutil", ["--pkg-info-plist", identifier], timeout: UpdaterConstants.commandTimeoutSeconds)
        guard result.succeeded,
              let plist = (try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), options: [], format: nil)) as? [String: Any],
              plist["pkgid"] as? String == identifier,
              let text = plist["pkg-version"] as? String else { return nil }
        return Version(text)
    }
}
