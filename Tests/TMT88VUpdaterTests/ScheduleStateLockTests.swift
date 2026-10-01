import Foundation
import Testing
@testable import TMT88VUpdater

struct ScheduleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func nextCheckIsAtLeastTwentyFourHoursPlusJitter() {
        #expect(Schedule.nextCheck(after: now, random: FixedRandom(value: 0)) == now.addingTimeInterval(86_400))
        #expect(Schedule.nextCheck(after: now, random: FixedRandom(value: 1234)) == now.addingTimeInterval(86_400 + 1234))
        #expect(Schedule.nextCheck(after: now, random: FixedRandom(value: 999_999)) == now.addingTimeInterval(86_400 + 21_600))
    }

    @Test func realRandomStaysInsideTheWindow() {
        for _ in 0..<500 {
            let next = Schedule.nextCheck(after: now, random: SystemRandomSource())
            let delta = next.timeIntervalSince(now)
            #expect(delta >= 86_400 && delta <= 86_400 + 21_600)
        }
    }

    @Test func noStateInitializesAScheduleWithoutChecking() {
        let decision = Schedule.decide(state: UpdaterState(), now: now, random: FixedRandom(value: 500), force: false)
        #expect(decision == .initialize(nextCheckAt: now.addingTimeInterval(500)))
    }

    @Test func notDueBeforeTheScheduledTime() {
        var state = UpdaterState()
        state.nextCheckAt = now.addingTimeInterval(7200)
        #expect(Schedule.decide(state: state, now: now, random: FixedRandom(value: 0), force: false) == .notDue(until: now.addingTimeInterval(7200)))
    }

    @Test func dueAtAndAfterTheScheduledTime() {
        var state = UpdaterState()
        state.nextCheckAt = now
        #expect(Schedule.decide(state: state, now: now, random: FixedRandom(value: 0), force: false) == .due)
        state.nextCheckAt = now.addingTimeInterval(-10)
        #expect(Schedule.decide(state: state, now: now, random: FixedRandom(value: 0), force: false) == .due)
    }

    @Test func forceAlwaysChecks() {
        var state = UpdaterState()
        state.nextCheckAt = now.addingTimeInterval(80_000)
        #expect(Schedule.decide(state: state, now: now, random: FixedRandom(value: 0), force: true) == .due)
    }

    @Test func implausibleFutureScheduleIsResetNotObeyed() {
        var state = UpdaterState()
        state.nextCheckAt = now.addingTimeInterval(86_400 * 400)
        guard case .initialize = Schedule.decide(state: state, now: now, random: FixedRandom(value: 0), force: false) else {
            Issue.record("a schedule years in the future must be reset")
            return
        }
        var skewed = UpdaterState()
        skewed.nextCheckAt = now
        skewed.lastCheckAt = now.addingTimeInterval(86_400 * 30)
        guard case .initialize = Schedule.decide(state: skewed, now: now, random: FixedRandom(value: 0), force: false) else {
            Issue.record("a last-check time in the future must be reset")
            return
        }
    }
}

struct StateStoreTests {
    @Test func roundTrip() throws {
        let root = try TempRoot()
        let store = StateStore(path: root.paths.statePath)
        var state = UpdaterState()
        state.lastCheckAt = Date(timeIntervalSince1970: 1_800_000_000)
        state.nextCheckAt = Date(timeIntervalSince1970: 1_800_090_000)
        state.lastSeenVersion = "0.2.0"
        state.pendingInstall = PendingInstall(version: "0.2.0", startedAt: Date(timeIntervalSince1970: 1_800_000_100))
        try store.save(state)
        let loaded = store.load()
        #expect(loaded.problem == nil)
        #expect(loaded.state == state)
    }

    @Test func missingFileIsAnEmptyStateNotAProblem() throws {
        let root = try TempRoot()
        let loaded = StateStore(path: root.paths.statePath).load()
        #expect(loaded.state == UpdaterState())
        #expect(loaded.problem == nil)
    }

    @Test(arguments: ["", "garbage", "{", "[1,2,3]", "{\"nextCheckAt\": \"not a date\"}", "{\"nextCheckAt\": 5}"])
    func corruptStateIsSafelyEmptyAndReported(contents: String) throws {
        let root = try TempRoot()
        try contents.write(toFile: root.paths.statePath, atomically: true, encoding: .utf8)
        let loaded = StateStore(path: root.paths.statePath).load()
        #expect(loaded.state == UpdaterState())
        #expect(loaded.problem != nil)
    }

    @Test func saveReplacesAtomicallyAndLeavesNoTemporaryFile() throws {
        let root = try TempRoot()
        let store = StateStore(path: root.paths.statePath)
        try store.save(UpdaterState())
        var state = UpdaterState()
        state.lastSeenVersion = "9.9.9"
        try store.save(state)
        #expect(store.load().state.lastSeenVersion == "9.9.9")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.paths.stateDir).filter { $0.contains(".tmp.") }
        #expect(leftovers.isEmpty)
    }

    @Test func stateContainsNoSecrets() throws {
        let root = try TempRoot()
        try StateStore(path: root.paths.statePath).save(UpdaterState())
        let text = try String(contentsOfFile: root.paths.statePath, encoding: .utf8)
        #expect(text.count < 200)
    }
}

struct FileLockTests {
    @Test func secondAcquireFailsWhileHeldAndSucceedsAfterRelease() throws {
        let root = try TempRoot()
        let first = try #require(FileLock(path: root.paths.lockPath))
        #expect(FileLock(path: root.paths.lockPath) == nil)
        first.release()
        let second = FileLock(path: root.paths.lockPath)
        #expect(second != nil)
        second?.release()
    }

    @Test func staleLockFileLeftByACrashIsRecovered() throws {
        let root = try TempRoot()
        try "99999\n".write(toFile: root.paths.lockPath, atomically: true, encoding: .utf8)
        let lock = FileLock(path: root.paths.lockPath)
        #expect(lock != nil)
        lock?.release()
    }

    @Test func lockHeldByAnotherProcessIsRespectedAndDroppedWhenItDies() throws {
        let root = try TempRoot()
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", "use Fcntl qw(:flock); open(my $f, '>>', $ARGV[0]) or die; flock($f, LOCK_EX) or die; print \"locked\\n\"; STDOUT->flush; sleep 30;", root.paths.lockPath]
        let pipe = Pipe()
        holder.standardOutput = pipe
        try holder.run()
        _ = pipe.fileHandleForReading.availableData
        #expect(FileLock(path: root.paths.lockPath) == nil)
        holder.terminate()
        holder.waitUntilExit()
        let recovered = FileLock(path: root.paths.lockPath)
        #expect(recovered != nil)
        recovered?.release()
    }

    @Test func refusesToFollowASymlinkedLockPath() throws {
        let root = try TempRoot()
        let target = root.path + "/elsewhere"
        FileManager.default.createFile(atPath: target, contents: nil)
        symlink(target, root.paths.lockPath)
        #expect(FileLock(path: root.paths.lockPath) == nil)
    }
}
