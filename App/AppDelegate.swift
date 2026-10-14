import AppKit

/// AppKit lifecycle hooks SwiftUI does not expose.
///
/// Later milestones add: opening `.fxvault` files (pending imports) and the
/// clipboard check on terminate (tasks/todo.md §3).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// FX Vault keeps running when its window closes; closing the window locks the vault (D16).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
