import Foundation
import TMT88VUpdater

setlinebuf(stdout)

let usage = """
usage: tmt88v-updater [run [--force] | status | verify PACKAGE | --help]

  run [--force]   scheduled update check (what launchd runs hourly). Does nothing and uses no network unless a check is due.
  status          show installed version, configuration and schedule
  verify PACKAGE  run the full signature, Team ID, notarization and metadata verification on a local package

Updates come only from the official GitHub Releases URL and are installed only if signed by Developer ID Installer team
\(UpdaterConstants.requiredTeamID) and notarized.
"""

var paths = UpdaterPaths()
var updateURL = UpdaterConstants.officialUpdateURL
var dependencies = UpdaterDependencies()

#if TMT88V_UPDATER_TESTING
// Compiled ONLY into the developer test variant (-DTMT88V_UPDATER_TESTING). The shipped binary contains none of this.
let environment = ProcessInfo.processInfo.environment
if let root = environment["TMT88V_UPDATER_ROOT"] { paths = UpdaterPaths(root: root) }
if let override = environment["TMT88V_UPDATE_URL"], let url = URL(string: override) { updateURL = url }
if environment["TMT88V_UPDATER_ALLOW_HTTP"] == "1" {
    var downloader = CurlDownloader()
    downloader.allowInsecureForTesting = true
    dependencies.downloader = downloader
}
if let now = environment["TMT88V_UPDATER_FAKE_NOW"], let seconds = TimeInterval(now) {
    dependencies.clock = { Date(timeIntervalSince1970: seconds) }
}
if environment["TMT88V_UPDATER_ZERO_JITTER"] == "1" { dependencies.random = ZeroRandom() }
if let tools = environment["TMT88V_UPDATER_TOOLS_DIR"] { dependencies.runner = RedirectingRunner(directory: tools) }
dependencies.requiredOwnerUID = getuid()
let requireRoot = false
#else
let requireRoot = true
#endif

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "run"

switch command {
case "-h", "--help", "help", "--version":
    print(usage)
    exit(0)

case "status":
    let reader = InstalledVersionReader(runner: dependencies.runner)
    print("installed version: \(reader.read()?.description ?? "unknown (no package receipt)")")
    print("automatic updates: \(UpdaterConfig.load(path: paths.configPath))")
    let (state, problem) = StateStore(path: paths.statePath).load()
    if let problem { print("state: \(problem)") }
    print("last check:        \(state.lastCheckAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")")
    print("next check:        \(state.nextCheckAt.map { ISO8601DateFormatter().string(from: $0) } ?? "not scheduled")")
    print("last seen version: \(state.lastSeenVersion ?? "none")")
    print("update URL:        \(updateURL.absoluteString)")
    exit(0)

case "verify":
    guard arguments.count == 2 else { print(usage); exit(2) }
    let package = arguments[1]
    let verifier = PackageVerifier(runner: dependencies.runner)
    let work = NSTemporaryDirectory() + "tmt88v-verify-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: work) }
    do {
        let signer = try verifier.verifySignature(of: package)
        print("signature:    valid, \(signer.leafName)")
        let metadata = try verifier.readMetadata(of: package, workDirectory: work)
        print("metadata:     \(metadata.identifier) \(metadata.version)")
        try verifier.verifyGatekeeper(of: package, signer: signer)
        print("gatekeeper:   accepted, notarized")
        print("RESULT: package would be accepted for installation")
        exit(0)
    } catch {
        print("RESULT: REJECTED: \(error)")
        exit(1)
    }

case "run":
    let force = arguments.contains("--force")
    if requireRoot && getuid() != 0 {
        FileHandle.standardError.write(Data("tmt88v-updater run must be started by launchd as root\n".utf8))
        exit(1)
    }
    let outcome = UpdateEngine(paths: paths, updateURL: updateURL, dependencies: dependencies, log: UpdaterLog(path: paths.logPath, echoToStderr: isatty(STDERR_FILENO) != 0)).run(force: force)
    exit(outcome.exitCode)

default:
    print(usage)
    exit(2)
}

#if TMT88V_UPDATER_TESTING
struct ZeroRandom: RandomSource {
    func jitterSeconds(upTo maximum: Int) -> Int { 0 }
}

/// Test variant only: maps /usr/sbin/pkgutil etc. onto stub scripts in a directory.
struct RedirectingRunner: CommandRunning {
    let directory: String
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        let stub = directory + "/" + (executable as NSString).lastPathComponent
        let passthrough = ProcessInfo.processInfo.environment["TOOLS_STATE"].map { ["TOOLS_STATE": $0] } ?? [:]
        return ProcessCommandRunner(extraEnvironment: passthrough).run(FileManager.default.isExecutableFile(atPath: stub) ? stub : executable, arguments, timeout: timeout)
    }
}
#endif
