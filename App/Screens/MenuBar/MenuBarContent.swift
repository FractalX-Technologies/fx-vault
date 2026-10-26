import AppKit
import SwiftUI

/// The menu bar item's menu (board MenuBar): Quick Vault with its shortcut, Open FX Vault,
/// Review Sync · N pending… (only with something pending), Lock Now, Settings… and Quit.
struct MenuBarContent: View {
    let app: AppViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // The shortcut shows beside it; the menu answers it only while open (the hot key works
        // everywhere else).
        Button(QuickVaultCopy.title) {
            app.openQuickVault()
        }
        .keyboardShortcut(app.container.preferences.quickVaultShortcut.keyboardShortcut)
        .accessibilityIdentifier(AccessibilityID.MenuBar.quickVault)
        Button(MenuBarCopy.openApp) {
            app.openFXVault()
        }
        .accessibilityIdentifier(AccessibilityID.MenuBar.open)
        if app.offersSyncReview {
            Button(MenuBarCopy.reviewSync(count: app.pendingChangeCount)) {
                app.requestSyncReview()
            }
            .accessibilityIdentifier(AccessibilityID.MenuBar.reviewSync)
        }
        Divider()
        Button(MenuBarCopy.lockNow) {
            app.lock(trigger: .manual)
        }
        .disabled(!app.canLock)
        .accessibilityIdentifier(AccessibilityID.MenuBar.lockNow)
        Button(MenuBarCopy.settings) {
            // A menu bar item doesn't activate the app: the window would open behind others.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        .accessibilityIdentifier(AccessibilityID.MenuBar.settings)
        Divider()
        Button(MenuBarCopy.quit) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
        .accessibilityIdentifier(AccessibilityID.MenuBar.quit)
    }
}
