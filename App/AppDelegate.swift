import AppKit

/// AppKit lifecycle hooks SwiftUI does not expose.
///
/// Owns the app's dependencies (``bootstrap``), so both scenes and the terminate hook share one
/// ``AppViewModel``. Later milestones add opening `.fxvault` files (pending imports).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Built once, when SwiftUI creates the delegate (before any scene body runs).
    let bootstrap = AppBootstrap.forCurrentProcess()

    /// FX Vault keeps running when its window closes; closing the window locks the vault (D16).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clears FX Vault's clipboard contents, drops the keys and checkpoints the database (§5.9).
    func applicationWillTerminate(_ notification: Notification) {
        bootstrap.viewModel?.applicationWillTerminate()
    }
}
