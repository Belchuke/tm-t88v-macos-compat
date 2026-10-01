import Foundation
import Testing
@testable import TMT88VUpdater

struct EngineTests {
    @Test func disabledConfigExitsCleanlyWithoutAnyNetworkOrToolUse() throws {
        let h = try Harness()
        try h.root.writeConfig("{\"automaticUpdates\": false}")
        let outcome = h.engine().run()
        guard case .disabled = outcome else { Issue.record("expected disabled, got \(outcome)"); return }
        #expect(outcome.exitCode == 0)
        #expect(h.downloader.counter.requests == 0)
        #expect(h.runner.calls.isEmpty)
        #expect(h.root.logged("updates_disabled"))
    }

    @Test func malformedConfigDisablesUpdates() throws {
        let h = try Harness()
        try h.root.writeConfig("{ nope")
        guard case .disabled = h.engine().run() else { Issue.record("expected disabled"); return }
        #expect(h.downloader.counter.requests == 0)
        #expect(h.root.logText.contains("updates_disabled"))
    }

    @Test func freshInstallSchedulesWithoutTouchingTheNetwork() throws {
        let h = try Harness()
        let outcome = h.engine().run()
        #expect(outcome == .scheduleInitialized)
        #expect(h.downloader.counter.requests == 0)
        #expect(h.state().nextCheckAt == h.clock.now.addingTimeInterval(3600))
        #expect(h.state().lastCheckAt == nil)
    }

    @Test func notDueMakesNoNetworkRequest() throws {
        let h = try Harness()
        var state = UpdaterState()
        state.nextCheckAt = h.clock.now.addingTimeInterval(3600)
        try StateStore(path: h.root.paths.statePath).save(state)
        #expect(h.engine().run() == .notDue)
        #expect(h.downloader.counter.requests == 0)
        #expect(h.root.logged("check_skipped_not_due"))
    }

    @Test func dueRunsTheCheckAndPersistsTheNextSlotBeforeTheNetwork() throws {
        let h = try Harness()
        try h.makeDue()
        h.runner.installed = "0.2.0"
        let outcome = h.engine().run()
        #expect(outcome == .upToDate(installed: Version(0, 2, 0), available: Version(0, 2, 0)))
        #expect(h.downloader.counter.requests == 1)
        let state = h.state()
        #expect(state.lastCheckAt == h.clock.now)
        #expect(state.nextCheckAt == h.clock.now.addingTimeInterval(86_400 + 3600))
        #expect(state.lastSeenVersion == "0.2.0")
    }

    @Test func corruptStateIsResetSafelyAndNeverChecksImmediately() throws {
        let h = try Harness()
        try "{{{".write(toFile: h.root.paths.statePath, atomically: true, encoding: .utf8)
        #expect(h.engine().run() == .scheduleInitialized)
        #expect(h.downloader.counter.requests == 0)
        #expect(h.root.logged("state_reset"))
    }

    @Test func officialURLIsWhatTheEngineDownloads() throws {
        let h = try Harness()
        try h.makeDue()
        _ = h.engine().run()
        #expect(h.downloader.counter.lastURL == UpdaterConstants.officialUpdateURL)
    }

    @Test func newerVerifiedPackageIsInstalledAndTheNewVersionConfirmed() throws {
        let h = try Harness()
        try h.makeDue()
        let outcome = h.engine().run()
        #expect(outcome == .updated(from: Version(0, 1, 2), to: Version(0, 2, 0)))
        #expect(outcome.exitCode == 0)
        let install = try #require(h.runner.calls.first { $0.executable == "/usr/sbin/installer" })
        #expect(install.arguments.first == "-pkg")
        #expect(install.arguments.suffix(2) == ["-target", "/"])
        #expect(h.runner.installed == "0.2.0")
        for event in ["updater_started", "current_version", "download_started", "download_completed", "verification_started",
                      "downloaded_version", "verification_succeeded", "install_started", "install_succeeded", "update_complete"] {
            #expect(h.root.logged(event), "missing log event \(event)")
        }
        let state = h.state()
        #expect(state.lastSuccessfulUpdateAt != nil)
        #expect(state.pendingInstall == nil)
        #expect(!FileManager.default.fileExists(atPath: h.root.paths.updateInProgressPath))
    }

    @Test func installerRunsFromAPrivateDirectoryThatIsCleanedUp() throws {
        let h = try Harness()
        try h.makeDue()
        _ = h.engine().run()
        let install = try #require(h.runner.calls.first { $0.executable == "/usr/sbin/installer" })
        let package = install.arguments[1]
        #expect(package.hasPrefix(h.root.paths.stateDir + "/download-"))
        #expect(!FileManager.default.fileExists(atPath: package))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: h.root.paths.stateDir).filter { $0.hasPrefix("download-") }
        #expect(leftovers.isEmpty)
    }

    // MARK: security: the installer must never run

    @Test(arguments: [
        ("same version", "0.1.2"), ("older version", "0.1.1"), ("much older version", "0.0.1"),
    ])
    func notNewerPackagesAreNeverInstalled(_ label: String, version: String) throws {
        let h = try Harness()
        try h.makeDue()
        h.runner.packageVersion = version
        let outcome = h.engine().run()
        guard case .upToDate = outcome else { Issue.record("\(label): expected upToDate, got \(outcome)"); return }
        #expect(!h.runner.installerWasCalled)
        #expect(h.root.logged("already_up_to_date"))
        #expect(!h.runner.called("/usr/sbin/spctl"), "Gatekeeper is only consulted for a package that would actually be installed")
    }

    @Test func malformedVersionIsNeverInstalled() throws {
        let h = try Harness()
        try h.makeDue()
        h.runner.packageVersion = "0.2.0-evil"
        let outcome = h.engine().run()
        guard case .verificationFailed = outcome else { Issue.record("got \(outcome)"); return }
        #expect(outcome.exitCode == 1)
        #expect(!h.runner.installerWasCalled)
    }

    @Test func wrongIdentifierIsNeverInstalled() throws {
        let h = try Harness()
        try h.makeDue()
        h.runner.packageIdentifier = "com.example.evil.pkg"
        guard case .verificationFailed = h.engine().run() else { Issue.record("expected verificationFailed"); return }
        #expect(!h.runner.installerWasCalled)
        #expect(h.root.logged("verification_failed"))
    }

    @Test func unsignedIsNeverInstalled() throws {
        let h = try Harness()
        try h.makeDue()
        h.runner.signatureStatus = 1
        guard case .verificationFailed = h.engine().run() else { Issue.record("expected verificationFailed"); return }
        #expect(!h.runner.installerWasCalled)
        #expect(!h.runner.called("/usr/sbin/spctl"))
    }

    @Test func wrongTeamIsNeverInstalled() throws {
        let h = try Harness()
        try h.makeDue()
        h.runner.leaf = "Developer ID Installer: Attacker (ZZZZZ99999)"
        guard case .verificationFailed = h.engine().run() else { Issue.record("expected verificationFailed"); return }
        #expect(!h.runner.installerWasCalled)
        #expect(h.root.logText.contains("ZZZZZ99999"))
    }

    @Test func gatekeeperRejectionIsNeverInstalled() throws {
        let h = try Harness()
        try h.makeDue()
        h.runner.gatekeeperVerdict = false
        h.runner.gatekeeperStatus = 3
        guard case .verificationFailed = h.engine().run() else { Issue.record("expected verificationFailed"); return }
        #expect(!h.runner.installerWasCalled)
    }

    @Test func unnotarizedIsNeverInstalled() throws {
        let h = try Harness()
        try h.makeDue()
        h.runner.gatekeeperSource = "Unnotarized Developer ID"
        h.runner.gatekeeperVerdict = false
        h.runner.gatekeeperStatus = 3
        guard case .verificationFailed = h.engine().run() else { Issue.record("expected verificationFailed"); return }
        #expect(!h.runner.installerWasCalled)
    }

    @Test func corruptedPackageIsNeverInstalled() throws {
        var h = try Harness()
        try h.makeDue()
        h.downloader.result = .success(Data("<html>404 not a package</html>".utf8))
        guard case .verificationFailed = h.engine().run() else { Issue.record("expected verificationFailed"); return }
        #expect(!h.runner.installerWasCalled)
        #expect(h.runner.callCount("/usr/sbin/pkgutil") == 1, "only the installed-version receipt read; the bogus file is rejected on its magic bytes before any tool parses it")
    }

    // MARK: installer outcomes

    @Test func failedInstallerIsLoggedAndTheInstallationIsLeftAlone() throws {
        let h = try Harness()
        try h.makeDue()
        h.runner.installerStatus = 1
        let outcome = h.engine().run()
        guard case .installFailed = outcome else { Issue.record("expected installFailed, got \(outcome)"); return }
        #expect(outcome.exitCode == 1)
        #expect(h.root.logged("install_failed"))
        #expect(h.root.logged("installer_output"))
        #expect(h.runner.installed == "0.1.2")
        #expect(h.state().pendingInstall == nil)
        #expect(!FileManager.default.fileExists(atPath: h.root.paths.updateInProgressPath))
        #expect(h.state().lastSuccessfulUpdateAt == nil)
    }

    @Test func installerSuccessWithoutTheNewVersionIsAFailure() throws {
        let h = try Harness()
        try h.makeDue()
        h.runner.installerUpdatesReceipt = false
        guard case .installFailed(let reason) = h.engine().run() else { Issue.record("expected installFailed"); return }
        #expect(reason.contains("expected 0.2.0"))
        #expect(h.state().lastSuccessfulUpdateAt == nil)
    }

    @Test func failureDoesNotCauseARetryBeforeTheNextSlot() throws {
        let h = try Harness()
        try h.makeDue()
        h.runner.installerStatus = 1
        _ = h.engine().run()
        h.clock.now = h.clock.now.addingTimeInterval(3600)
        #expect(h.engine().run() == .notDue)
        #expect(h.downloader.counter.requests == 1)
    }

    @Test func installerAlreadyRunningDefersWithoutDownloading() throws {
        let h = try Harness()
        try h.makeDue()
        h.runner.installerRunning = true
        #expect(h.engine().run() == .installerBusy)
        #expect(h.downloader.counter.requests == 0)
        #expect(!h.runner.installerWasCalled)
    }

    // MARK: downloads

    @Test(arguments: [DownloadError.httpError, .timeout, .tooLarge, .incomplete, .emptyFile, .transport(6, "no DNS")])
    func downloadFailuresExitCleanlyAndDoNotTouchTheInstallation(error: DownloadError) throws {
        var h = try Harness()
        try h.makeDue()
        h.downloader.result = .failure(error)
        let outcome = h.engine().run()
        guard case .downloadFailed = outcome else { Issue.record("expected downloadFailed"); return }
        #expect(outcome.exitCode == 0)
        #expect(!h.runner.installerWasCalled)
        #expect(h.root.logged("download_failed"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: h.root.paths.stateDir).filter { $0.hasPrefix("download-") }
        #expect(leftovers.isEmpty)
        #expect(h.state().nextCheckAt == h.clock.now.addingTimeInterval(86_400 + 3600))
    }

    @Test func unknownInstalledVersionRefusesToUpdate() throws {
        let h = try Harness()
        try h.makeDue()
        h.runner.installed = nil
        let outcome = h.engine().run()
        #expect(outcome == .installedVersionUnknown)
        #expect(h.downloader.counter.requests == 0)
    }

    // MARK: locking and environment

    @Test func secondUpdaterExitsCleanly() throws {
        let h = try Harness()
        try h.makeDue()
        let held = try #require(FileLock(path: h.root.paths.lockPath))
        defer { held.release() }
        let outcome = h.engine().run()
        #expect(outcome == .lockHeld)
        #expect(outcome.exitCode == 0)
        #expect(h.downloader.counter.requests == 0)
        #expect(h.root.logged("updater_already_running"))
    }

    @Test func lockIsReleasedAfterARun() throws {
        let h = try Harness()
        _ = h.engine().run()
        let lock = FileLock(path: h.root.paths.lockPath)
        #expect(lock != nil)
        lock?.release()
    }

    @Test func worldWritableStateDirectoryIsRefused() throws {
        let h = try Harness()
        chmod(h.root.paths.stateDir, 0o777)
        guard case .unsafeEnvironment = h.engine().run() else { Issue.record("expected unsafeEnvironment"); return }
        #expect(h.downloader.counter.requests == 0)
    }

    @Test func symlinkedStateDirectoryIsRefused() throws {
        let h = try Harness()
        let real = h.root.path + "/realstate"
        try FileManager.default.moveItem(atPath: h.root.paths.stateDir, toPath: real)
        symlink(real, h.root.paths.stateDir)
        guard case .unsafeEnvironment = h.engine().run() else { Issue.record("expected unsafeEnvironment"); return }
    }

    @Test func stateDirectoryOwnedBySomeoneElseIsRefused() throws {
        let h = try Harness()
        let dependencies = UpdaterDependencies(clock: { h.clock.now }, runner: h.runner, downloader: h.downloader, requiredOwnerUID: getuid() &+ 1)
        let engine = UpdateEngine(paths: h.root.paths, updateURL: UpdaterConstants.officialUpdateURL, dependencies: dependencies, log: UpdaterLog(path: nil))
        guard case .unsafeEnvironment = engine.run() else { Issue.record("expected unsafeEnvironment"); return }
    }

    // MARK: self-update

    @Test func pendingInstallLeftByAReplacedUpdaterIsRecognisedOnTheNextRun() throws {
        let h = try Harness()
        var state = UpdaterState()
        state.pendingInstall = PendingInstall(version: "0.2.0", startedAt: h.clock.now.addingTimeInterval(-60))
        state.nextCheckAt = h.clock.now.addingTimeInterval(10_000)
        try StateStore(path: h.root.paths.statePath).save(state)
        FileManager.default.createFile(atPath: h.root.paths.updateInProgressPath, contents: Data("1\n".utf8))
        h.runner.installed = "0.2.0"
        _ = h.engine().run()
        #expect(h.root.logText.contains("\"recovered\":true"))
        #expect(h.state().pendingInstall == nil)
        #expect(h.state().lastSuccessfulUpdateAt != nil)
        #expect(!FileManager.default.fileExists(atPath: h.root.paths.updateInProgressPath))
    }

    @Test func incompletePendingInstallIsReportedAndCleared() throws {
        let h = try Harness()
        var state = UpdaterState()
        state.pendingInstall = PendingInstall(version: "0.2.0", startedAt: h.clock.now)
        state.nextCheckAt = h.clock.now.addingTimeInterval(10_000)
        try StateStore(path: h.root.paths.statePath).save(state)
        _ = h.engine().run()
        #expect(h.root.logged("install_incomplete"))
        #expect(h.state().pendingInstall == nil)
    }

    @Test func updateInProgressMarkerExistsWhileTheInstallerRuns() throws {
        let h = try Harness()
        try h.makeDue()
        let marker = h.root.paths.updateInProgressPath
        final class Seen: @unchecked Sendable { var value = false }
        let seen = Seen()
        let observing = ObservingRunner(wrapped: h.runner) { executable in
            if executable == "/usr/sbin/installer" { seen.value = FileManager.default.fileExists(atPath: marker) }
        }
        let clock = h.clock
        let dependencies = UpdaterDependencies(clock: { clock.now }, runner: observing, downloader: h.downloader, requiredOwnerUID: getuid())
        _ = UpdateEngine(paths: h.root.paths, updateURL: UpdaterConstants.officialUpdateURL, dependencies: dependencies, log: UpdaterLog(path: nil)).run()
        #expect(seen.value)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }
}

struct ObservingRunner: CommandRunning {
    let wrapped: ScenarioRunner
    let onRun: (String) -> Void
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CommandResult {
        onRun(executable)
        return wrapped.run(executable, arguments, timeout: timeout)
    }
}
