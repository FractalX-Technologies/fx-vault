import AppKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

@MainActor
@Suite("AutoLockManager")
struct AutoLockManagerTests {
    nonisolated private static let signalTriggers: [LockTrigger] = [
        .systemSleep, .displaySleep, .sessionResignedActive, .protectedDataUnavailable,
        .screenLocked, .screensaverStarted,
    ]
    nonisolated private static let liveTickInterval = Duration.milliseconds(50)

    @Test(arguments: signalTriggers)
    func everySystemSignalLocksSynchronously(_ trigger: LockTrigger) async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.app.didUnlock()
        #expect(harness.app.phase == .unlocked)

        harness.signals.send(trigger)

        // Phase A happened before send(_:) returned: no suspension point in between.
        #expect(harness.vaultManager.session.isLocked)
        #expect(harness.app.phase == .locked)
        #expect(harness.app.lastLockTrigger == trigger)
        #expect(harness.app.lockCount == 1)
    }

    /// The live ticker fires on a utility queue. Its handler once inherited the app's default
    /// MainActor isolation and trapped on the first tick, which the fake ticker cannot show.
    @Test(.timeLimit(.minutes(1)))
    func liveTickerDeliversTicksOnTheMainActor() async {
        let ticker = DispatchInactivityTicker()
        let probe = TickProbe()
        await withCheckedContinuation { continuation in
            probe.continuation = continuation
            ticker.start(interval: Self.liveTickInterval) {
                ticker.stop()
                probe.fire()
            }
        }
        ticker.stop()
        #expect(probe.ticks >= 1)
    }

    @Test func checksEveryFifteenSeconds() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        #expect(harness.ticker.interval == Timeouts.autoLockCheckInterval)
        #expect(harness.idle.isStarted)
    }

    @Test func inactivityTimeoutLocks() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.app.didUnlock()
        harness.preferences.autoLockMinutes = 1

        harness.clock.advance(by: .seconds(59))
        harness.ticker.tick()
        #expect(harness.app.phase == .unlocked)

        harness.clock.advance(by: .seconds(1))
        harness.ticker.tick()
        #expect(harness.app.phase == .locked)
        #expect(harness.vaultManager.session.isLocked)
        #expect(harness.app.lastLockTrigger == .inactivity)
    }

    @Test func interactionResetsTheTimer() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.app.didUnlock()
        harness.preferences.autoLockMinutes = 1

        harness.clock.advance(by: .seconds(50))
        harness.idle.interact()
        harness.clock.advance(by: .seconds(50))
        harness.ticker.tick()
        #expect(harness.app.phase == .unlocked)

        harness.clock.advance(by: .seconds(10))
        harness.ticker.tick()
        #expect(harness.app.phase == .locked)
    }

    @Test func timeoutChangeAppliesImmediately() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.app.didUnlock()
        harness.clock.advance(by: .seconds(120))
        harness.ticker.tick()
        #expect(harness.app.phase == .unlocked)
        harness.preferences.autoLockMinutes = 2
        harness.ticker.tick()
        #expect(harness.app.phase == .locked)
    }

    @Test func syncAssertionSuspendsInactivityOnly() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.app.didUnlock()
        harness.preferences.autoLockMinutes = 1
        let autoLock = harness.container.autoLock

        let assertion = autoLock.beginSyncActivity()
        #expect(autoLock.isSyncActive)
        harness.clock.advance(by: .seconds(600))
        harness.ticker.tick()
        #expect(harness.app.phase == .unlocked)

        // The full timeout starts again once the sync ends.
        assertion.release()
        assertion.release()
        #expect(!autoLock.isSyncActive)
        harness.clock.advance(by: .seconds(30))
        harness.ticker.tick()
        #expect(harness.app.phase == .unlocked)
        harness.clock.advance(by: .seconds(30))
        harness.ticker.tick()
        #expect(harness.app.phase == .locked)
    }

    @Test func syncAssertionDoesNotBlockSystemSignals() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.app.didUnlock()
        let assertion = harness.container.autoLock.beginSyncActivity()
        harness.signals.send(.systemSleep)
        #expect(harness.app.phase == .locked)
        assertion.release()
    }

    @Test func assertionReleasesOnDeinit() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let autoLock = harness.container.autoLock
        do {
            let assertion = autoLock.beginSyncActivity()
            #expect(autoLock.isSyncActive)
            _ = assertion
        }
        #expect(!autoLock.isSyncActive)
    }

    @Test func closingTheMainWindowLocks() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.app.didUnlock()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.Layout.windowMinWidth, height: Theme.Layout.windowMinHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        harness.app.attachMainWindow(window)
        #expect(!window.isRestorable)

        window.close()

        #expect(harness.app.phase == .locked)
        #expect(harness.app.lastLockTrigger == .windowClosed)
    }

    @Test func lockedVaultIgnoresRepeatedTriggers() async throws {
        let harness = try await TestHarness(vault: .locked)
        harness.signals.send(.systemSleep)
        harness.ticker.tick()
        #expect(harness.app.phase == .locked)
        #expect(harness.app.lockCount == 0)
    }

    @Test func noVaultIgnoresTriggers() async throws {
        let harness = try await TestHarness(vault: .none)
        harness.signals.send(.screenLocked)
        #expect(harness.app.phase == .onboarding)
        #expect(harness.app.lockCount == 0)
    }

    @Test func stopDetachesSources() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        harness.container.autoLock.stop()
        #expect(!harness.container.autoLock.isRunning)
        harness.signals.send(.systemSleep)
        #expect(harness.app.phase == .unlocked)
    }
}

/// Resumes a waiting test once, on the first tick of a live ticker.
@MainActor
private final class TickProbe {
    var continuation: CheckedContinuation<Void, Never>?
    private(set) var ticks = 0

    func fire() {
        ticks += 1
        continuation?.resume()
        continuation = nil
    }
}
