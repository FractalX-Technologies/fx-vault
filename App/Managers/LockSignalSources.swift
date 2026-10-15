import AppKit
import VaultCore

/// Why the vault locked (§5.7, D16). Every trigger can only lock, never unlock.
enum LockTrigger: String, CaseIterable, Sendable {
    /// The user chose Lock (toolbar, menu, ⌃⌘L).
    case manual
    /// No interaction with FX Vault for the auto-lock timeout.
    case inactivity
    /// `NSWorkspace.willSleepNotification`.
    case systemSleep
    /// `NSWorkspace.screensDidSleepNotification`.
    case displaySleep
    /// `NSWorkspace.sessionDidResignActiveNotification` (fast user switching).
    case sessionResignedActive
    /// `NSApplication.protectedDataWillBecomeUnavailableNotification`.
    case protectedDataUnavailable
    /// The distributed notification `com.apple.screenIsLocked` (best effort).
    case screenLocked
    /// The distributed notification `com.apple.screensaver.didstart` (best effort).
    case screensaverStarted
    /// The main window was closed.
    case windowClosed
}

/// Reports user interaction with FX Vault (key, mouse and scroll events).
protocol IdleEventSource: AnyObject {
    func start(onInteraction: @escaping @MainActor () -> Void)
    func stop()
}

/// Reports system events that must lock the vault immediately.
protocol LockSignalSource: AnyObject {
    func start(onSignal: @escaping @MainActor (LockTrigger) -> Void)
    func stop()
}

/// Calls back periodically so the inactivity rule can be checked.
protocol InactivityTicker: AnyObject {
    func start(interval: Duration, onTick: @escaping @MainActor () -> Void)
    func stop()
}

// MARK: - Live sources

/// A local `NSEvent` monitor: only events sent to FX Vault count as activity (D16).
final class LocalEventIdleSource: IdleEventSource {
    private static let mask: NSEvent.EventTypeMask = [
        .keyDown, .flagsChanged,
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .mouseMoved, .scrollWheel,
    ]

    private var monitor: Any?

    func start(onInteraction: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: Self.mask) { event in
            MainActor.assumeIsolated {
                onInteraction()
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

/// Sleep, display sleep, session switch, protected-data loss, screen lock and screensaver
/// (§5.7). The screen lock and screensaver notifications are undocumented and can be spoofed;
/// they are lock-only triggers, so a spoof can do no harm.
final class SystemLockSignalSource: LockSignalSource {
    static let screenIsLocked = Notification.Name("com.apple.screenIsLocked")
    static let screensaverDidStart = Notification.Name("com.apple.screensaver.didstart")

    private var observations: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    func start(onSignal: @escaping @MainActor (LockTrigger) -> Void) {
        stop()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, .systemSleep, onSignal)
        observe(workspace, NSWorkspace.screensDidSleepNotification, .displaySleep, onSignal)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive, onSignal)
        observe(
            NotificationCenter.default,
            .NSApplicationProtectedDataWillBecomeUnavailable,
            .protectedDataUnavailable,
            onSignal
        )
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Self.screenIsLocked, .screenLocked, onSignal)
        observe(distributed, Self.screensaverDidStart, .screensaverStarted, onSignal)
    }

    func stop() {
        for observation in observations {
            observation.center.removeObserver(observation.token)
        }
        observations.removeAll()
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ trigger: LockTrigger,
        _ onSignal: @escaping @MainActor (LockTrigger) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                onSignal(trigger)
            }
        }
        observations.append((center, token))
    }
}

/// A `DispatchSourceTimer` on a utility queue: it keeps firing while a menu is tracking or a
/// modal panel runs, unlike a run-loop timer (§5.7).
final class DispatchInactivityTicker: InactivityTicker {
    private static let leeway = DispatchTimeInterval.seconds(1)
    private var timer: (any DispatchSourceTimer)?

    func start(interval: Duration, onTick: @escaping @MainActor () -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let seconds = interval.timeInterval
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: Self.leeway)
        timer.setEventHandler {
            Task { @MainActor in
                onTick()
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - Inert sources (previews and the app while it hosts tests)

/// A source that never fires. Previews and the test host use it so no system notification can
/// lock their in-memory vault mid-test.
final class InertLockSources: IdleEventSource, LockSignalSource, InactivityTicker {
    func start(onInteraction: @escaping @MainActor () -> Void) {}
    func start(onSignal: @escaping @MainActor (LockTrigger) -> Void) {}
    func start(interval: Duration, onTick: @escaping @MainActor () -> Void) {}
    func stop() {}
}
