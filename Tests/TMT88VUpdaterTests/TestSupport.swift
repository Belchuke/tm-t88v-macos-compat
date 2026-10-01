import Foundation
@testable import TMT88VUpdater

struct FixedRandom: RandomSource {
    var value: Int
    func jitterSeconds(upTo maximum: Int) -> Int { min(value, maximum) }
}

final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

final class TempRoot {
    let path: String
    let paths: UpdaterPaths

    init() throws {
        path = NSTemporaryDirectory() + "tmt88v-updater-test-\(UUID().uuidString)"
        paths = UpdaterPaths(root: path)
        try FileManager.default.createDirectory(atPath: paths.stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.createDirectory(atPath: paths.logDir, withIntermediateDirectories: true)
        chmod(paths.stateDir, 0o755)
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func writeConfig(_ text: String) throws {
        try text.write(toFile: paths.configPath, atomically: true, encoding: .utf8)
    }

    var logText: String { (try? String(contentsOfFile: paths.logPath, encoding: .utf8)) ?? "" }
    func logged(_ event: String) -> Bool { logText.contains("\"event\":\"\(event)\"") }
}

struct FakeDownloader: PackageDownloading {
    final class Counter: @unchecked Sendable { var requests = 0; var lastURL: URL? }
    var counter = Counter()
    var result: Result<Data, DownloadError> = .success(Data("xar!".utf8) + Data(repeating: 0, count: 64))

    func download(from url: URL, to path: String, maxBytes: Int64) throws {
        counter.requests += 1
        counter.lastURL = url
        switch result {
        case .success(let data): FileManager.default.createFile(atPath: path, contents: data)
        case .failure(let error): throw error
        }
    }
}

/// Plays the roles of pkgutil, spctl, installer and pgrep with the real output formats.
final class ScenarioRunner: CommandRunning {
    var installed: String? = "0.1.2"
    var packageVersion = "0.2.0"
    var packageIdentifier = UpdaterConstants.packageIdentifier
    var distributionIdentifier: String?
    var distributionVersion: String?
    var leaf = "Developer ID Installer: Jacob Belchuke (P3WL6DBK59)"
    var chain: [String]?
    var signatureStatus: Int32 = 0
    var expandStatus: Int32 = 0
    var componentCount = 1
    var gatekeeperVerdict = true
    var gatekeeperSource = "Notarized Developer ID"
    var gatekeeperOrigin: String?
    var gatekeeperStatus: Int32 = 0
    var installerStatus: Int32 = 0
    var installerUpdatesReceipt = true
    var installerRunning = false
    var calls: [(executable: String, arguments: [String])] = []

    func called(_ executable: String) -> Bool { calls.contains { $0.executable == executable } }
    func callCount(_ executable: String) -> Int { calls.filter { $0.executable == executable }.count }
    var installerWasCalled: Bool { called("/usr/sbin/installer") }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        calls.append((executable, arguments))
        switch (executable, arguments.first ?? "") {
        case ("/usr/sbin/pkgutil", "--pkg-info-plist"):
            guard let installed else { return CommandResult(status: 1, errorOutput: "No receipt") }
            return CommandResult(status: 0, output: """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>pkg-version</key><string>\(installed)</string><key>pkgid</key><string>\(UpdaterConstants.packageIdentifier)</string></dict></plist>
            """)
        case ("/usr/sbin/pkgutil", "--check-signature"):
            guard signatureStatus == 0 else { return CommandResult(status: signatureStatus, output: "Package \"x.pkg\":\n   Status: no signature\n") }
            return CommandResult(status: 0, output: Self.signatureOutput(chain ?? [leaf, "Developer ID Certification Authority", "Apple Root CA"]))
        case ("/usr/sbin/pkgutil", "--expand"):
            return expand(into: arguments[2])
        case ("/usr/sbin/spctl", "--assess"):
            if arguments.contains("--raw") {
                return CommandResult(status: gatekeeperStatus, output: Self.spctlRaw(verdict: gatekeeperVerdict, source: gatekeeperSource))
            }
            return CommandResult(status: gatekeeperStatus, output: "x.pkg: accepted\nsource=\(gatekeeperSource)\norigin=\(gatekeeperOrigin ?? leaf)\n")
        case ("/usr/sbin/installer", _):
            if installerStatus == 0, installerUpdatesReceipt { installed = packageVersion }
            return CommandResult(status: installerStatus, output: "installer: Package name is TM-T88V\ninstaller: The install was successful.\n")
        case ("/usr/bin/pgrep", _):
            return CommandResult(status: installerRunning ? 0 : 1)
        default:
            return CommandResult(status: 127, errorOutput: "unexpected command \(executable)")
        }
    }

    private func expand(into directory: String) -> CommandResult {
        guard expandStatus == 0 else { return CommandResult(status: expandStatus, errorOutput: "cannot expand") }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let refID = distributionIdentifier ?? packageIdentifier
        let refVersion = distributionVersion ?? packageVersion
        let distribution = """
        <?xml version="1.0" encoding="utf-8"?>
        <installer-gui-script minSpecVersion="2">
            <choice id="default"><pkg-ref id="\(refID)"/></choice>
            <pkg-ref id="\(refID)" version="\(refVersion)" onConclusion="none">#component.pkg</pkg-ref>
        </installer-gui-script>
        """
        try? distribution.write(toFile: directory + "/Distribution", atomically: true, encoding: .utf8)
        for index in 0..<componentCount {
            let component = directory + "/" + (index == 0 ? "component.pkg" : "other\(index).pkg")
            try? fm.createDirectory(atPath: component, withIntermediateDirectories: true)
            let info = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<pkg-info identifier=\"\(packageIdentifier)\" version=\"\(packageVersion)\" install-location=\"/\"/>\n"
            try? info.write(toFile: component + "/PackageInfo", atomically: true, encoding: .utf8)
        }
        return CommandResult(status: 0)
    }

    static func signatureOutput(_ chain: [String]) -> String {
        var text = "Package \"x.pkg\":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Notarization: trusted by the Apple notary service\n   Signed with a trusted timestamp on: 2026-10-01 19:24:59 +0000\n   Certificate Chain:\n"
        for (index, name) in chain.enumerated() {
            text += "    \(index + 1). \(name)\n       Expires: 2027-02-01 22:12:15 +0000\n       SHA256 Fingerprint:\n           E7 79 27 0C DE AE 5A EB 5D 6C 13 B5 A7 B2 67 8D 10 F3 F5 70 BC 74 \n           7F A4 22 1D 7E DF 36 BC 5C D6\n       ------------------------------------------------------------------------\n"
        }
        return text
    }

    static func spctlRaw(verdict: Bool, source: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>assessment:authority</key><dict><key>assessment:authority:source</key><string>\(source)</string></dict>
        <key>assessment:verdict</key><\(verdict ? "true" : "false")/>
        </dict></plist>
        """
    }
}

struct Harness {
    let root: TempRoot
    let clock = Clock()
    let runner = ScenarioRunner()
    var downloader = FakeDownloader()
    var random = FixedRandom(value: 3600)

    init() throws { root = try TempRoot() }

    func engine(url: URL = UpdaterConstants.officialUpdateURL) -> UpdateEngine {
        let clock = self.clock
        let dependencies = UpdaterDependencies(
            clock: { clock.now }, random: random, runner: runner, downloader: downloader, requiredOwnerUID: getuid()
        )
        return UpdateEngine(paths: root.paths, updateURL: url, dependencies: dependencies, log: UpdaterLog(path: root.paths.logPath, clock: { clock.now }))
    }

    func state() -> UpdaterState { StateStore(path: root.paths.statePath).load().state }

    /// A state in which a check is due now.
    func makeDue() throws {
        var state = UpdaterState()
        state.nextCheckAt = clock.now.addingTimeInterval(-60)
        try StateStore(path: root.paths.statePath).save(state)
    }
}
