import Foundation

public enum DownloadError: Error, Equatable, CustomStringConvertible {
    case insecureURL
    case httpError
    case timeout
    case tooLarge
    case incomplete
    case transport(Int32, String)
    case emptyFile

    public var description: String {
        switch self {
        case .insecureURL: "download URL is not https"
        case .httpError: "server returned an HTTP error (for example 404)"
        case .timeout: "download timed out"
        case .tooLarge: "download exceeds the size limit"
        case .incomplete: "download ended before the whole file arrived"
        case .transport(let code, let message): "transfer failed (curl exit \(code)): \(message)"
        case .emptyFile: "download produced an empty file"
        }
    }
}

public protocol PackageDownloading {
    func download(from url: URL, to path: String, maxBytes: Int64) throws
}

/// Downloads with the system curl: HTTPS only (also across redirects), TLS 1.2+, no .curlrc, no netrc, bounded time and size.
public struct CurlDownloader: PackageDownloading {
    /// Test builds and unit tests only: allows plain http to a local test server. The production updater never sets this.
    public var allowInsecureForTesting = false
    public var connectTimeout = UpdaterConstants.connectTimeoutSeconds
    public var totalTimeout = UpdaterConstants.downloadTimeoutSeconds
    public var userAgent = "TMT88VCompat-Updater"

    public init() {}

    public static func arguments(
        url: URL, output: String, maxBytes: Int64, connectTimeout: Int, totalTimeout: Int, allowInsecure: Bool, userAgent: String
    ) -> [String] {
        let protocols = allowInsecure ? "=http,https" : "=https"
        return [
            "-q",
            "--silent", "--show-error", "--fail",
            "--location", "--max-redirs", "5",
            "--proto", protocols, "--proto-redir", protocols,
            "--tlsv1.2",
            "--connect-timeout", String(connectTimeout),
            "--max-time", String(totalTimeout),
            "--max-filesize", String(maxBytes),
            "--user-agent", userAgent,
            "--output", output,
            url.absoluteString,
        ]
    }

    public func download(from url: URL, to path: String, maxBytes: Int64) throws {
        guard allowInsecureForTesting || url.scheme == "https" else { throw DownloadError.insecureURL }
        let errPath = path + ".curl-stderr"
        FileManager.default.createFile(atPath: errPath, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(atPath: errPath) }
        guard let errHandle = FileHandle(forWritingAtPath: errPath) else { throw DownloadError.transport(-1, "cannot create stderr file") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = Self.arguments(
            url: url, output: path, maxBytes: maxBytes, connectTimeout: connectTimeout, totalTimeout: totalTimeout,
            allowInsecure: allowInsecureForTesting, userAgent: userAgent
        )
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errHandle
        try process.run()

        var oversized = false
        while process.isRunning {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            if size > maxBytes {
                oversized = true
                process.terminate()
                break
            }
            usleep(100_000)
        }
        process.waitUntilExit()
        try? errHandle.close()

        let stderrText = String(decoding: (FileManager.default.contents(atPath: errPath) ?? Data()).prefix(500), as: UTF8.self)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        if oversized || size > maxBytes {
            try? FileManager.default.removeItem(atPath: path)
            throw DownloadError.tooLarge
        }
        switch process.terminationStatus {
        case 0: break
        case 22: try? FileManager.default.removeItem(atPath: path); throw DownloadError.httpError
        case 28: try? FileManager.default.removeItem(atPath: path); throw DownloadError.timeout
        case 63: try? FileManager.default.removeItem(atPath: path); throw DownloadError.tooLarge
        case 18, 56: try? FileManager.default.removeItem(atPath: path); throw DownloadError.incomplete
        case let code:
            try? FileManager.default.removeItem(atPath: path)
            throw DownloadError.transport(code, stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard size > 0 else { try? FileManager.default.removeItem(atPath: path); throw DownloadError.emptyFile }
    }
}
