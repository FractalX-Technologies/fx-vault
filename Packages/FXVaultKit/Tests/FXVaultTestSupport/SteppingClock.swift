import Foundation
import os
import VaultCore

/// A test clock whose `sleep` returns at once after advancing time by the requested duration,
/// so retry windows (verification, freshRepo, backoffs) run instantly and deterministically.
/// Every sleep is recorded. Use `ManualClock` when a test must control when time moves.
public final class SteppingClock: VaultClock {
    private struct State: Sendable {
        public var now: Date
        public var uptime: Duration = .zero
        public var sleeps: [Duration] = []
    }

    public static let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let state: OSAllocatedUnfairLock<State>

    public init(now: Date = SteppingClock.start) {
        state = OSAllocatedUnfairLock(initialState: State(now: now))
    }

    public var now: Date {
        state.withLock { $0.now }
    }

    public var uptime: Duration {
        state.withLock { $0.uptime }
    }

    /// Every sleep requested, in order.
    public var sleeps: [Duration] {
        state.withLock { $0.sleeps }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock { state in
            state.sleeps.append(duration)
            state.uptime += duration
            state.now = state.now.addingTimeInterval(duration.timeInterval)
        }
        await Task.yield()
    }

    /// Moves the wall clock only (clock skew).
    public func setWallClock(to date: Date) {
        state.withLock { $0.now = date }
    }
}
