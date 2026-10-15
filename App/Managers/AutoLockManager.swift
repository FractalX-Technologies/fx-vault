import AppKit
import os
import VaultCore

/// Counts the active ``SyncActivityAssertion``s. Thread-safe, so a sync running off the main
/// actor can hold an assertion.
nonisolated final class SyncActivityCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var isActive: Bool {
        count.withLock { $0 > 0 }
    }

    fileprivate func increment() {
        count.withLock { $0 += 1 }
    }

    fileprivate func decrement() {
        count.withLock { $0 = max(0, $0 - 1) }
    }
}

/// Held while a sync runs: the inactivity rule is suspended until every assertion is released
/// (D16). Every other lock trigger still locks. Released by ``release()`` or on deinit.
nonisolated final class SyncActivityAssertion: Sendable {
    private let counter: SyncActivityCounter
    private let isReleased = OSAllocatedUnfairLock(initialState: false)

    fileprivate init(counter: SyncActivityCounter) {
        self.counter = counter
        counter.increment()
    }

    func release() {
        let shouldDecrement = isReleased.withLock { released -> Bool in
            defer { released = true }
            return !released
        }
        if shouldDecrement {
            counter.decrement()
        }
    }

    deinit {
        release()
    }
}

/// Locks the vault after FX Vault inactivity and on system events (§5.7, D16).
///
/// - **Inactivity:** ``IdleEventSource`` stamps the last interaction with the clock's monotonic
///   `uptime` (`ContinuousClock` in the app, so it keeps advancing during sleep). The
///   ``InactivityTicker`` checks every ``Timeouts/autoLockCheckInterval``; the vault locks when
///   the elapsed time reaches the timeout, unless a ``SyncActivityAssertion`` is held.
/// - **Immediate:** every ``LockSignalSource`` signal and closing the main window.
///
/// The manager only reports triggers; the owner's `onLock` runs the synchronous Phase A (§5.8)
/// before any suspension point.
final class AutoLockManager {
    private let clock: any VaultClock
    private let idleSource: any IdleEventSource
    private let signalSource: any LockSignalSource
    private let ticker: any InactivityTicker
    private let timeout: () -> Duration
    private let syncActivity = SyncActivityCounter()

    private var lastInteraction: Duration
    private var onLock: ((LockTrigger) -> Void)?
    private var windowObservation: (any NSObjectProtocol)?
    private weak var observedWindow: NSWindow?

    /// - Parameter timeout: read on every check, so a Preferences change applies immediately.
    init(
        clock: any VaultClock,
        idleSource: any IdleEventSource,
        signalSource: any LockSignalSource,
        ticker: any InactivityTicker,
        timeout: @escaping () -> Duration
    ) {
        self.clock = clock
        self.idleSource = idleSource
        self.signalSource = signalSource
        self.ticker = ticker
        self.timeout = timeout
        lastInteraction = clock.uptime
    }

    var isRunning: Bool {
        onLock != nil
    }

    /// True while at least one sync assertion is held.
    var isSyncActive: Bool {
        syncActivity.isActive
    }

    /// Starts every source. `onLock` is called on the main actor for each trigger.
    func start(onLock: @escaping (LockTrigger) -> Void) {
        stop()
        self.onLock = onLock
        recordInteraction()
        idleSource.start { [weak self] in
            self?.recordInteraction()
        }
        signalSource.start { [weak self] trigger in
            self?.fire(trigger)
        }
        ticker.start(interval: Timeouts.autoLockCheckInterval) { [weak self] in
            self?.checkInactivity()
        }
    }

    func stop() {
        idleSource.stop()
        signalSource.stop()
        ticker.stop()
        onLock = nil
    }

    /// Resets the inactivity timer (also called after every unlock).
    func recordInteraction() {
        lastInteraction = clock.uptime
    }

    /// Locks when the inactivity timeout has elapsed and no sync is running.
    func checkInactivity() {
        let now = clock.uptime
        if syncActivity.isActive {
            // The timer is suspended during a sync: the full timeout starts again afterwards.
            lastInteraction = now
            return
        }
        if now - lastInteraction >= timeout() {
            lastInteraction = now
            fire(.inactivity)
        }
    }

    /// Suspends the inactivity rule until the returned assertion is released.
    func beginSyncActivity() -> SyncActivityAssertion {
        SyncActivityAssertion(counter: syncActivity)
    }

    /// Locks when `window` (the main window) closes. Replaces any previously observed window.
    func observeClose(of window: NSWindow) {
        guard window !== observedWindow else { return }
        if let windowObservation {
            NotificationCenter.default.removeObserver(windowObservation)
        }
        observedWindow = window
        windowObservation = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fire(.windowClosed)
            }
        }
    }

    private func fire(_ trigger: LockTrigger) {
        guard let onLock else { return }
        AppLog.vault.info("Lock trigger: \(trigger.rawValue, privacy: .public)")
        onLock(trigger)
    }
}
