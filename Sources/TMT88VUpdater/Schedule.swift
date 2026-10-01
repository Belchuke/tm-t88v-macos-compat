import Foundation

public protocol RandomSource {
    /// A value in 0...maximum (inclusive).
    func jitterSeconds(upTo maximum: Int) -> Int
}

public struct SystemRandomSource: RandomSource {
    public init() {}
    public func jitterSeconds(upTo maximum: Int) -> Int { Int.random(in: 0...max(0, maximum)) }
}

public enum ScheduleDecision: Equatable, Sendable {
    /// No schedule exists yet (fresh install or unusable state): set one, do not use the network.
    case initialize(nextCheckAt: Date)
    case notDue(until: Date)
    case due
}

public enum Schedule {
    /// The next check is at least 24 hours away, plus 0-6 hours of jitter. The jitter is chosen once, here, and persisted,
    /// so no process ever sleeps for it.
    public static func nextCheck(after now: Date, random: RandomSource) -> Date {
        let jitter = random.jitterSeconds(upTo: UpdaterConstants.maximumJitterSeconds)
        return now.addingTimeInterval(TimeInterval(UpdaterConstants.minimumIntervalSeconds + jitter))
    }

    public static func decide(state: UpdaterState, now: Date, random: RandomSource, force: Bool) -> ScheduleDecision {
        if force { return .due }
        guard let next = state.nextCheckAt else {
            return .initialize(nextCheckAt: now.addingTimeInterval(TimeInterval(random.jitterSeconds(upTo: UpdaterConstants.maximumJitterSeconds))))
        }
        let ceiling = TimeInterval(UpdaterConstants.minimumIntervalSeconds + UpdaterConstants.maximumJitterSeconds + 3600)
        if next > now.addingTimeInterval(ceiling) || (state.lastCheckAt.map { $0 > now.addingTimeInterval(3600) } ?? false) {
            return .initialize(nextCheckAt: now.addingTimeInterval(TimeInterval(random.jitterSeconds(upTo: UpdaterConstants.maximumJitterSeconds))))
        }
        return now >= next ? .due : .notDue(until: next)
    }
}
