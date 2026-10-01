import Foundation

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public var errorOutput: String
    public var timedOut: Bool

    public init(status: Int32, output: String = "", errorOutput: String = "", timedOut: Bool = false) {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
        self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 && !timedOut }
}

public protocol CommandRunning {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult
}

/// Runs a system tool by absolute path with a minimal, fixed environment. Output goes to private temporary files, so a
/// chatty child can never block on a full pipe.
public struct ProcessCommandRunner: CommandRunning {
    private let extraEnvironment: [String: String]

    /// `extraEnvironment` exists for the developer test variant only; the shipped updater always passes an empty dictionary.
    public init(extraEnvironment: [String: String] = [:]) {
        self.extraEnvironment = extraEnvironment
    }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        let directory = NSTemporaryDirectory() + "tmt88v-cmd-\(UUID().uuidString)"
        let outPath = directory + ".out"
        let errPath = directory + ".err"
        FileManager.default.createFile(atPath: outPath, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errPath, contents: nil, attributes: [.posixPermissions: 0o600])
        defer {
            try? FileManager.default.removeItem(atPath: outPath)
            try? FileManager.default.removeItem(atPath: errPath)
        }
        guard let outHandle = FileHandle(forWritingAtPath: outPath), let errHandle = FileHandle(forWritingAtPath: errPath) else {
            return CommandResult(status: -1, errorOutput: "could not create private output files")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"].merging(extraEnvironment) { _, new in new }
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, errorOutput: "could not start \(executable): \(error)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                let grace = Date().addingTimeInterval(3)
                while process.isRunning, Date() < grace { usleep(50_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            usleep(50_000)
        }
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()

        let limit = 2 * 1024 * 1024
        func read(_ path: String) -> String {
            let data = FileManager.default.contents(atPath: path) ?? Data()
            return String(decoding: data.prefix(limit), as: UTF8.self)
        }
        return CommandResult(status: process.terminationStatus, output: read(outPath), errorOutput: read(errPath), timedOut: timedOut)
    }
}
