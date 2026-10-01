import Foundation

public final class UpdaterLog: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL?
    private let maxBytes: Int
    private let keep: Int
    private let echoToStderr: Bool
    private var handle: FileHandle?
    private var written = 0
    private let clock: () -> Date

    public init(path: String?, maxBytes: Int = 1_000_000, keep: Int = 3, echoToStderr: Bool = false, clock: @escaping () -> Date = Date.init) {
        fileURL = path.map { URL(fileURLWithPath: $0) }
        self.maxBytes = maxBytes
        self.keep = keep
        self.echoToStderr = echoToStderr
        self.clock = clock
    }

    public func event(_ name: String, _ fields: [String: Any] = [:]) {
        var record = fields
        record["event"] = name
        record["ts"] = ISO8601DateFormatter().string(from: clock())
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        if echoToStderr { FileHandle.standardError.write(line) }
        guard let fileURL else { return }
        if handle == nil { open(fileURL) }
        if written + line.count > maxBytes { rotate(fileURL) }
        handle?.write(line)
        written += line.count
    }

    private func open(_ url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o644]) }
        handle = try? FileHandle(forWritingTo: url)
        written = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func rotate(_ url: URL) {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.removeItem(atPath: "\(url.path).\(keep)")
        for index in stride(from: keep - 1, through: 1, by: -1) {
            try? manager.moveItem(atPath: "\(url.path).\(index)", toPath: "\(url.path).\(index + 1)")
        }
        try? manager.moveItem(atPath: url.path, toPath: "\(url.path).1")
        open(url)
    }
}
