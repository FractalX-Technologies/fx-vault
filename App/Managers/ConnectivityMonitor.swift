import Foundation
import Network
import Observation
import VaultCore

/// The system's default network path (`NWPath`), reduced to what FX Vault needs.
nonisolated struct NetworkPathModel: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// A usable route exists (Wi-Fi, Ethernet, a hotspot, a VPN).
        case satisfied
        /// No usable route (Wi-Fi off or not joined, cable out).
        case unsatisfied
        /// A route exists but must be brought up first (an on-demand VPN). Treated as offline.
        case requiresConnection
    }

    let status: Status
    /// Low Data Mode or a constrained interface. Still online: GitHub stays reachable.
    let isConstrained: Bool

    init(status: Status, isConstrained: Bool = false) {
        self.status = status
        self.isConstrained = isConstrained
    }

    var isOnline: Bool {
        status == .satisfied
    }

    static let online = NetworkPathModel(status: .satisfied)
    static let offline = NetworkPathModel(status: .unsatisfied)
}

nonisolated extension NetworkPathModel {
    init(_ path: NWPath) {
        let status: Status = switch path.status {
        case .satisfied: .satisfied
        case .requiresConnection: .requiresConnection
        case .unsatisfied: .unsatisfied
        @unknown default: .unsatisfied
        }
        self.init(status: status, isConstrained: path.isConstrained)
    }
}

/// Reports the default network path: once when started, then on every change.
protocol NetworkPathSource: AnyObject {
    func start(onUpdate: @escaping @MainActor (NetworkPathModel) -> Void)
    func stop()
}

/// `NWPathMonitor` on a private utility queue. Only path metadata is read: it sends nothing on
/// the network (no probes, no requests to GitHub).
final class NWPathMonitorSource: NetworkPathSource {
    private static let queueLabel = "io.fractalx.fxvault.connectivity"
    private var monitor: NWPathMonitor?

    func start(onUpdate: @escaping @MainActor (NetworkPathModel) -> Void) {
        stop()
        let monitor = NWPathMonitor()
        // The handler runs on the monitor's queue, so it must not inherit the class's default
        // MainActor isolation (lessons.md: an inferred-MainActor closure traps off the main
        // thread).
        monitor.pathUpdateHandler = { @Sendable path in
            let model = NetworkPathModel(path)
            Task { @MainActor in
                onUpdate(model)
            }
        }
        monitor.start(queue: DispatchQueue(label: Self.queueLabel, qos: .utility))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}

/// A source that reports one fixed path when started (SwiftUI previews and the test host, so no
/// system state reaches an in-memory vault).
final class FixedNetworkPathSource: NetworkPathSource {
    private let path: NetworkPathModel

    init(_ path: NetworkPathModel = .online) {
        self.path = path
    }

    func start(onUpdate: @escaping @MainActor (NetworkPathModel) -> Void) {
        onUpdate(path)
    }

    func stop() {}
}

/// Something that reacts when the internet connection is lost or comes back (held weakly).
protocol ConnectivityObserving: AnyObject {
    func connectivityDidChange(isOnline: Bool)
}

/// Internet reachability for the main window (v0.2.0 connectivity banner).
///
/// - The first path the source reports applies at once, so a launch without a network shows
///   the offline banner immediately.
/// - Every later change applies only after it held for `debounce` on the injected clock: a path
///   that flaps (Wi-Fi roaming, a VPN reconnecting) and returns to the shown state never reaches
///   the UI or the observers. More updates in the same direction while waiting (one transition
///   reports several paths) do not restart the wait.
/// - A constrained path (Low Data Mode) is online.
@Observable
final class ConnectivityMonitor {
    /// False while the system reports no usable route. True until the first report.
    private(set) var isOnline = true
    /// The last reported path is constrained (Low Data Mode).
    private(set) var isConstrained = false

    @ObservationIgnored private let source: any NetworkPathSource
    @ObservationIgnored private let clock: any VaultClock
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var hasReceivedPath = false
    @ObservationIgnored private(set) var isStarted = false
    /// The pending change waiting out the debounce (internal so tests can await it).
    @ObservationIgnored private(set) var settleTask: Task<Void, Never>?
    /// The state ``settleTask`` will apply.
    @ObservationIgnored private var pendingIsOnline: Bool?
    @ObservationIgnored private var observers: [WeakConnectivityObserver] = []

    init(
        source: any NetworkPathSource,
        clock: any VaultClock,
        debounce: Duration = Theme.Durations.connectivityDebounce
    ) {
        self.source = source
        self.clock = clock
        self.debounce = debounce
    }

    /// Starts listening. Idempotent.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        source.start { [weak self] path in
            self?.receive(path)
        }
    }

    /// Stops listening and drops a pending change.
    func stop() {
        source.stop()
        cancelPendingChange()
        isStarted = false
    }

    /// Registers `observer` for online / offline changes. Held weakly.
    func addObserver(_ observer: any ConnectivityObserving) {
        observers.removeAll { $0.observer == nil || $0.observer === observer }
        observers.append(WeakConnectivityObserver(observer: observer))
    }

    private func receive(_ path: NetworkPathModel) {
        isConstrained = path.isConstrained
        guard hasReceivedPath else {
            hasReceivedPath = true
            apply(isOnline: path.isOnline)
            return
        }
        let target = path.isOnline
        guard target != isOnline else {
            // Back to the shown state before the change settled: it never reaches the UI.
            cancelPendingChange()
            return
        }
        // Already waiting for this change: further updates of the same transition (interfaces
        // appearing, Wi-Fi power events) must not restart the wait.
        guard pendingIsOnline != target else { return }
        cancelPendingChange()
        pendingIsOnline = target
        let clock = clock
        let debounce = debounce
        settleTask = Task { [weak self] in
            do {
                try await clock.sleep(for: debounce)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.apply(isOnline: target)
        }
    }

    private func cancelPendingChange() {
        settleTask?.cancel()
        settleTask = nil
        pendingIsOnline = nil
    }

    private func apply(isOnline online: Bool) {
        settleTask = nil
        pendingIsOnline = nil
        guard online != isOnline else { return }
        isOnline = online
        observers.removeAll { $0.observer == nil }
        for entry in observers {
            entry.observer?.connectivityDidChange(isOnline: online)
        }
    }
}

private struct WeakConnectivityObserver {
    weak var observer: (any ConnectivityObserving)?
}
