import Foundation
import Testing
import VaultCore

@Suite("ManualClock and SystemClock")
struct ClockTests {
    @Test func startsAtTheGivenTime() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = ManualClock(now: start)
        #expect(clock.now == start)
        #expect(clock.uptime == .zero)
        #expect(ManualClock().now == ManualClock.defaultStart)
    }

    @Test func advanceMovesWallTimeAndUptime() {
        let clock = ManualClock()
        clock.advance(by: .seconds(90))
        clock.advance(by: .milliseconds(500))
        #expect(clock.uptime == .milliseconds(90_500))
        #expect(clock.now == ManualClock.defaultStart.addingTimeInterval(90.5))
        clock.advance(by: .seconds(-5))
        #expect(clock.uptime == .milliseconds(90_500))
    }

    @Test func wallClockChangesLeaveUptimeAlone() {
        let clock = ManualClock()
        clock.advance(by: .seconds(10))
        let skewed = Date(timeIntervalSince1970: 0)
        clock.setWallClock(to: skewed)
        #expect(clock.now == skewed)
        #expect(clock.uptime == .seconds(10))
    }

    @Test func sleeperResumesOnlyAtItsDeadline() async throws {
        let clock = ManualClock()
        let task = Task { try await clock.sleep(for: Timeouts.rateLimitBackoff) }
        await clock.waitForSleepers(count: 1)
        clock.advance(by: .seconds(59))
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(1))
        try await task.value
        #expect(clock.sleeperCount == 0)
    }

    @Test func sleepersResumeInDeadlineOrder() async throws {
        let clock = ManualClock()
        let order = OrderRecorder()
        let late = Task {
            try await clock.sleep(for: .seconds(30))
            await order.append("late")
        }
        await clock.waitForSleepers(count: 1)
        let early = Task {
            try await clock.sleep(for: .seconds(10))
            await order.append("early")
        }
        await clock.waitForSleepers(count: 2)
        clock.advance(by: .seconds(10))
        try await early.value
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(20))
        try await late.value
        #expect(await order.values == ["early", "late"])
    }

    @Test func zeroAndNegativeSleepsReturnImmediately() async throws {
        let clock = ManualClock()
        try await clock.sleep(for: .zero)
        try await clock.sleep(for: .seconds(-1))
        #expect(clock.sleeperCount == 0)
    }

    @Test func cancellationResumesASleeperWithCancellationError() async {
        let clock = ManualClock()
        let task = Task { try await clock.sleep(for: .seconds(60)) }
        await clock.waitForSleepers(count: 1)
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(clock.sleeperCount == 0)
    }

    @Test func alreadyCancelledTaskDoesNotSleep() async {
        let clock = ManualClock()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(for: .seconds(60))
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(clock.sleeperCount == 0)
    }

    @Test func usableThroughTheProtocol() async throws {
        let manual = ManualClock()
        let clock: any VaultClock = manual
        let task = Task { try await clock.sleep(for: Timeouts.writeBatchGap) }
        await manual.waitForSleepers(count: 1)
        manual.advance(by: Timeouts.writeBatchGap)
        try await task.value
        #expect(clock.uptime == Timeouts.writeBatchGap)
    }

    @Test func systemClockIsMonotonicAndSleeps() async throws {
        let clock = SystemClock()
        let first = clock.uptime
        try await clock.sleep(for: .milliseconds(1))
        #expect(clock.uptime > first)
        #expect(abs(clock.now.timeIntervalSinceNow) < Timeouts.ghDefault.timeInterval)
    }
}

/// Records completion order across tasks.
private actor OrderRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
