import Foundation

public enum RunOutcome: Equatable, Sendable {
    case lockHeld
    case disabled(String)
    case unsafeEnvironment(String)
    case scheduleInitialized
    case notDue
    case installerBusy
    case installedVersionUnknown
    case downloadFailed(String)
    case verificationFailed(String)
    case upToDate(installed: Version, available: Version)
    case installFailed(String)
    case updated(from: Version, to: Version)

    /// 0 for every ordinary outcome (including no network). Non-zero only when something needs a human to look.
    public var exitCode: Int32 {
        switch self {
        case .unsafeEnvironment, .installedVersionUnknown, .verificationFailed, .installFailed: 1
        default: 0
        }
    }
}

public struct UpdaterDependencies {
    public var clock: () -> Date
    public var random: RandomSource
    public var runner: CommandRunning
    public var downloader: PackageDownloading
    /// The uid that must own the state directory. 0 in production; tests run unprivileged.
    public var requiredOwnerUID: uid_t

    public init(
        clock: @escaping () -> Date = Date.init,
        random: RandomSource = SystemRandomSource(),
        runner: CommandRunning = ProcessCommandRunner(),
        downloader: PackageDownloading = CurlDownloader(),
        requiredOwnerUID: uid_t = 0
    ) {
        self.clock = clock
        self.random = random
        self.runner = runner
        self.downloader = downloader
        self.requiredOwnerUID = requiredOwnerUID
    }
}

public final class UpdateEngine {
    private let paths: UpdaterPaths
    private let updateURL: URL
    private let deps: UpdaterDependencies
    private let log: UpdaterLog

    public init(paths: UpdaterPaths, updateURL: URL, dependencies: UpdaterDependencies, log: UpdaterLog) {
        self.paths = paths
        self.updateURL = updateURL
        deps = dependencies
        self.log = log
    }

    public func run(force: Bool = false) -> RunOutcome {
        log.event("updater_started", ["pid": Int(getpid()), "force": force])

        if let problem = stateDirectoryProblem() {
            log.event("unsafe_environment", ["reason": problem])
            return .unsafeEnvironment(problem)
        }
        guard let lock = FileLock(path: paths.lockPath) else {
            log.event("updater_already_running")
            return .lockHeld
        }
        defer { lock.release() }

        let setting = UpdaterConfig.load(path: paths.configPath)
        if case .disabled(let reason) = setting {
            log.event("updates_disabled", ["reason": reason])
            return .disabled(reason)
        }
        if case .enabled(let fromFile) = setting, !fromFile { log.event("config_missing_using_default") }

        let store = StateStore(path: paths.statePath)
        var (state, problem) = store.load()
        if let problem { log.event("state_reset", ["reason": problem]) }

        let reader = InstalledVersionReader(runner: deps.runner)
        let installed = reader.read()
        recoverPendingInstall(&state, installed: installed, store: store)

        let now = deps.clock()
        switch Schedule.decide(state: state, now: now, random: deps.random, force: force) {
        case .initialize(let next):
            state.nextCheckAt = next
            save(state, store)
            log.event("schedule_initialized", ["nextCheckAt": iso(next)])
            return .scheduleInitialized
        case .notDue(let until):
            log.event("check_skipped_not_due", ["nextCheckAt": iso(until)])
            return .notDue
        case .due:
            break
        }

        guard let installed else {
            log.event("installed_version_unknown", ["reason": "no readable package receipt for \(UpdaterConstants.packageIdentifier)"])
            return .installedVersionUnknown
        }
        log.event("current_version", ["version": installed.description])

        if installerIsRunning() {
            log.event("check_deferred_installer_busy")
            return .installerBusy
        }

        // Persist the next slot BEFORE touching the network: a crash or failure can never cause a retry storm.
        state.lastCheckAt = now
        state.nextCheckAt = Schedule.nextCheck(after: now, random: deps.random)
        save(state, store)

        guard let work = makeWorkDirectory() else {
            log.event("unsafe_environment", ["reason": "could not create a private download directory"])
            return .unsafeEnvironment("could not create a private download directory")
        }
        defer { try? FileManager.default.removeItem(atPath: work) }
        let package = work + "/TMT88VCompat.pkg"

        log.event("checking_release", ["url": updateURL.absoluteString])
        log.event("download_started")
        do {
            try deps.downloader.download(from: updateURL, to: package, maxBytes: UpdaterConstants.maxDownloadBytes)
        } catch {
            log.event("download_failed", ["reason": "\(error)"])
            return .downloadFailed("\(error)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: package)[.size] as? Int64) ?? 0
        log.event("download_completed", ["bytes": size])

        let verifier = PackageVerifier(runner: deps.runner)
        log.event("verification_started")
        let signer: SignerInfo
        let metadata: PackageMetadata
        do {
            signer = try verifier.verifySignature(of: package)
            metadata = try verifier.readMetadata(of: package, workDirectory: work)
        } catch {
            log.event("verification_failed", ["reason": "\(error)"])
            return .verificationFailed("\(error)")
        }
        log.event("downloaded_version", ["version": metadata.version.description, "team": signer.teamID])
        state.lastSeenVersion = metadata.version.description

        guard metadata.version > installed else {
            save(state, store)
            log.event("already_up_to_date", [
                "installed": installed.description, "available": metadata.version.description,
                "relation": metadata.version == installed ? "same" : "older",
            ])
            return .upToDate(installed: installed, available: metadata.version)
        }

        do {
            try verifier.verifyGatekeeper(of: package, signer: signer)
        } catch {
            log.event("verification_failed", ["reason": "\(error)"])
            save(state, store)
            return .verificationFailed("\(error)")
        }
        log.event("verification_succeeded", ["version": metadata.version.description])

        return install(package: package, from: installed, to: metadata.version, state: &state, store: store)
    }

    // MARK: installing

    private func install(package: String, from installed: Version, to target: Version, state: inout UpdaterState, store: StateStore) -> RunOutcome {
        // Written first: if the installer replaces this very binary and this process dies, the next run recognises the result.
        state.pendingInstall = PendingInstall(version: target.description, startedAt: deps.clock())
        save(state, store)
        FileManager.default.createFile(atPath: paths.updateInProgressPath, contents: Data("\(getpid())\n".utf8), attributes: [.posixPermissions: 0o644])
        defer { try? FileManager.default.removeItem(atPath: paths.updateInProgressPath) }

        log.event("install_started", ["from": installed.description, "to": target.description])
        let result = deps.runner.run("/usr/sbin/installer", ["-pkg", package, "-target", "/"], timeout: UpdaterConstants.installerTimeoutSeconds)
        logInstallerOutput(result)

        let after = InstalledVersionReader(runner: deps.runner).read()
        if result.succeeded, after == target {
            state.pendingInstall = nil
            state.lastSuccessfulUpdateAt = deps.clock()
            save(state, store)
            log.event("install_succeeded", ["version": target.description])
            log.event("update_complete", ["from": installed.description, "to": target.description])
            return .updated(from: installed, to: target)
        }

        state.pendingInstall = nil
        save(state, store)
        let reason: String
        if result.timedOut { reason = "installer timed out" }
        else if !result.succeeded { reason = "installer exited with status \(result.status)" }
        else { reason = "installer reported success but the installed version is \(after?.description ?? "unknown"), expected \(target)" }
        log.event("install_failed", ["reason": reason, "installedAfter": after?.description ?? "unknown"])
        return .installFailed(reason)
    }

    private func logInstallerOutput(_ result: CommandResult) {
        let lines = (result.output + "\n" + result.errorOutput)
            .split(separator: "\n").map { String($0.prefix(300)) }.suffix(40)
        log.event("installer_output", ["status": Int(result.status), "lines": Array(lines)])
    }

    private func recoverPendingInstall(_ state: inout UpdaterState, installed: Version?, store: StateStore) {
        guard let pending = state.pendingInstall else { return }
        if let installed, let target = Version(pending.version), installed >= target {
            log.event("update_complete", ["recovered": true, "version": installed.description])
            state.lastSuccessfulUpdateAt = deps.clock()
        } else {
            log.event("install_incomplete", ["expected": pending.version, "installed": installed?.description ?? "unknown"])
        }
        state.pendingInstall = nil
        save(state, store)
        try? FileManager.default.removeItem(atPath: paths.updateInProgressPath)
    }

    // MARK: environment

    private func installerIsRunning() -> Bool {
        for name in ["installer", "Installer"] {
            if deps.runner.run("/usr/bin/pgrep", ["-x", name], timeout: 10).status == 0 { return true }
        }
        return false
    }

    /// The state directory must be a real directory owned by the required uid and not writable by anyone else.
    private func stateDirectoryProblem() -> String? {
        var info = stat()
        guard lstat(paths.stateDir, &info) == 0 else { return "state directory is missing" }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return "state path is not a real directory (symlink?)" }
        guard info.st_uid == deps.requiredOwnerUID else { return "state directory is owned by uid \(info.st_uid)" }
        guard info.st_mode & 0o022 == 0 else { return "state directory is writable by group or others" }
        return nil
    }

    private func makeWorkDirectory() -> String? {
        removeStaleWorkDirectories()
        var template = Array((paths.stateDir + "/download-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { return nil }
        return String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func removeStaleWorkDirectories() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: paths.stateDir)) ?? [] where name.hasPrefix("download-") {
            let path = paths.stateDir + "/" + name
            if let modified = (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date, deps.clock().timeIntervalSince(modified) > 86_400 {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    private func save(_ state: UpdaterState, _ store: StateStore) {
        do { try store.save(state) } catch { log.event("state_write_failed", ["reason": "\(error)"]) }
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
