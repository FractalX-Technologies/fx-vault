import Foundation
import os

/// FX Vault's time source: wall-clock time, monotonic uptime and cancellable sleeps (§12.2).
///
/// Named `VaultClock` rather than `Clock` so it does not shadow the standard library's `Clock`
/// protocol in every module that imports VaultCore. Production code takes `any VaultClock` and
/// uses ``SystemClock``; tests inject ``ManualClock`` (rate-limit backoff, verification retries,
/// the freshRepo window, the 14-day password rule, journal retention).
public protocol VaultClock: Sendable {
    /// Wall-clock time: timestamps, the 14-day rule, journal retention. Can jump.
    var now: Date { get }
    /// Monotonic time since the clock's origin. Never goes backwards and keeps advancing while
    /// the Mac sleeps. Use it for elapsed-time windows.
    var uptime: Duration { get }
    /// Suspends for `duration`. Throws `CancellationError` if the task is cancelled.
    func sleep(for duration: Duration) async throws
}

/// The real clock: `Date()` for wall time, `ContinuousClock` for uptime and sleeping.
public struct SystemClock: VaultClock {
    private let origin: ContinuousClock.Instant

    public init() {
        origin = ContinuousClock.now
    }

    public var now: Date {
        Date()
    }

    public var uptime: Duration {
        ContinuousClock.now - origin
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration, clock: .continuous)
    }
}

/// A clock that only moves when a test calls ``advance(by:)`` (§12.2).
///
/// Public so every module's tests can use it. Sleepers resume in deadline order once uptime
/// reaches their deadline; cancelling a sleeping task resumes it with `CancellationError`.
/// Use ``waitForSleepers(count:)`` to wait until the code under test has started sleeping
/// before advancing, which keeps tests deterministic without real delays.
public final class ManualClock: VaultClock {
    /// The default wall-clock start: 2001-01-01T00:00:00Z (reference date), fixed for tests.
    public static let defaultStart = Date(timeIntervalSinceReferenceDate: 0)

    private struct Sleeper: Sendable {
        let id: UInt64
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct Waiter: Sendable {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State: Sendable {
        var now: Date
        var uptime: Duration = .zero
        var nextID: UInt64 = 0
        /// Sleep calls that started but have not registered or finished yet.
        var startingIDs: Set<UInt64> = []
        /// Starting sleep calls that were cancelled before registering.
        var cancelledIDs: Set<UInt64> = []
        var sleepers: [Sleeper] = []
        var waiters: [Waiter] = []

        /// Removes and returns the waiters satisfied by the current sleeper count.
        mutating func takeSatisfiedWaiters() -> [Waiter] {
            let count = sleepers.count
            let satisfied = waiters.filter { $0.count <= count }
            waiters.removeAll { $0.count <= count }
            return satisfied
        }
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(now: Date = ManualClock.defaultStart) {
        state = OSAllocatedUnfairLock(initialState: State(now: now))
    }

    public var now: Date {
        state.withLock { $0.now }
    }

    public var uptime: Duration {
        state.withLock { $0.uptime }
    }

    /// Number of tasks currently suspended in ``sleep(for:)``.
    public var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    /// Moves wall time and uptime forward by `duration` and resumes every sleeper whose deadline
    /// has been reached, earliest first. Negative durations are ignored.
    public func advance(by duration: Duration) {
        guard duration > .zero else { return }
        let due: [Sleeper] = state.withLock { state in
            state.uptime += duration
            state.now = state.now.addingTimeInterval(duration.timeInterval)
            let uptime = state.uptime
            let due = state.sleepers
                .filter { $0.deadline <= uptime }
                .sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
            state.sleepers.removeAll { $0.deadline <= uptime }
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    /// Changes only the wall clock (simulates a clock change or skew); uptime and sleepers are
    /// unaffected.
    public func setWallClock(to date: Date) {
        state.withLock { $0.now = date }
    }

    /// Returns once at least `count` tasks are suspended in ``sleep(for:)``.
    public func waitForSleepers(count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isSatisfied = state.withLock { state -> Bool in
                if state.sleepers.count >= count { return true }
                state.waiters.append(Waiter(count: count, continuation: continuation))
                return false
            }
            if isSatisfied {
                continuation.resume()
            }
        }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            state.startingIDs.insert(state.nextID)
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(id: id, duration: duration, continuation: continuation)
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    private enum Registration {
        case resumeNow
        case cancelNow
        case registered([Waiter])
    }

    private func register(
        id: UInt64,
        duration: Duration,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        let registration = state.withLock { state -> Registration in
            state.startingIDs.remove(id)
            if state.cancelledIDs.remove(id) != nil { return .cancelNow }
            guard duration > .zero else { return .resumeNow }
            let sleeper = Sleeper(
                id: id,
                deadline: state.uptime + duration,
                continuation: continuation
            )
            state.sleepers.append(sleeper)
            return .registered(state.takeSatisfiedWaiters())
        }
        switch registration {
        case .resumeNow:
            continuation.resume()
        case .cancelNow:
            continuation.resume(throwing: CancellationError())
        case .registered(let waiters):
            for waiter in waiters {
                waiter.continuation.resume()
            }
        }
    }

    private func cancel(id: UInt64) {
        let sleeper = state.withLock { state -> Sleeper? in
            if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                return state.sleepers.remove(at: index)
            }
            if state.startingIDs.contains(id) {
                state.cancelledIDs.insert(id)
            }
            return nil
        }
        sleeper?.continuation.resume(throwing: CancellationError())
    }
}
