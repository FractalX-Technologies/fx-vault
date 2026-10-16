import AppKit
import UserNotifications

/// How a ping from a teammate gets attention (v0.5.0, T6).
protocol PingAlerting {
    /// `name` pinged this Mac. Frontmost: a sound. Otherwise a notification with the sound, so
    /// Focus and Do Not Disturb decide; the Dock icon bounces once either way.
    func alert(from name: String, isAppActive: Bool)
}

/// The system sound, `UNUserNotificationCenter` and the Dock.
struct SystemPingAlerts: PingAlerting {
    /// The ping sound (a macOS system sound).
    static let soundName = NSSound.Name("Glass")

    func alert(from name: String, isAppActive: Bool) {
        NSApp.requestUserAttention(.informationalRequest)
        guard !isAppActive else {
            NSSound(named: Self.soundName)?.play()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "ping.notification.title", defaultValue: "\(name) pinged you")
        content.body = String(localized: "ping.notification.body", defaultValue: "Open FX Vault to see who is nearby.")
        content.sound = UNNotificationSound(named: UNNotificationSoundName(Self.soundName))
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }
}

/// Records alerts instead of making noise (previews and tests).
final class RecordedPingAlerts: PingAlerting {
    private(set) var alerts: [(name: String, isAppActive: Bool)] = []

    func alert(from name: String, isAppActive: Bool) {
        alerts.append((name, isAppActive))
    }
}
