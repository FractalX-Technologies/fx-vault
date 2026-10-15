import CoreWLAN
import Foundation
import os

/// The Wi-Fi radio's power state (CoreWLAN), for nearby availability: peer-to-peer Wi-Fi
/// (AWDL, as AirDrop uses) works whenever Wi-Fi is on, even when it has joined no network and
/// `NWPathMonitor` lists no interface.
///
/// Reads only the power state of the default Wi-Fi interface: no scan, no network name (which
/// would need Location Services), nothing sent. ``init(onPowerChange:)`` also watches power
/// changes; the callback runs on CoreWLAN's thread.
nonisolated final class WiFiRadio: NSObject, CWEventDelegate, @unchecked Sendable {
    private let client = CWWiFiClient()
    private let onPowerChange: @Sendable () -> Void
    private let isStopped = OSAllocatedUnfairLock(initialState: false)

    /// True when this Mac has a Wi-Fi interface and its radio is on.
    static var isPoweredOn: Bool {
        CWWiFiClient.shared().interface()?.powerOn() ?? false
    }

    /// Starts watching Wi-Fi power changes. If CoreWLAN refuses to report them, power is still
    /// read on every network path change.
    init(onPowerChange: @escaping @Sendable () -> Void) {
        self.onPowerChange = onPowerChange
        super.init()
        client.delegate = self
        do {
            try client.startMonitoringEvent(with: .powerDidChange)
        } catch {
            AppLog.ui.error("Wi-Fi power changes cannot be observed; nearby availability follows network path changes only")
        }
    }

    /// Stops watching. Idempotent.
    func stop() {
        isStopped.withLock { $0 = true }
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        guard !isStopped.withLock({ $0 }) else { return }
        onPowerChange()
    }
}
