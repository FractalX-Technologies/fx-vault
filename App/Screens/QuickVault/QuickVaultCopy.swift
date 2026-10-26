import Foundation
import VaultCore

/// The quick vault's words (1.0 Q1; boards QuickVault-Search, -Place, -Locked).
nonisolated enum QuickVaultCopy {
    static let title = String(localized: "quickVault.title", defaultValue: "Quick Vault")
    static let prompt = String(localized: "quickVault.prompt", defaultValue: "Search places and names")
    static let recent = String(localized: "quickVault.recent", defaultValue: "Recent")
    static let open = String(localized: "quickVault.footer.open", defaultValue: "open")
    static let expand = String(localized: "quickVault.footer.expand", defaultValue: "expand")
    static let close = String(localized: "quickVault.footer.close", defaultValue: "close")
    static let expandButton = String(localized: "quickVault.expand", defaultValue: "Expand")
    static let expandHelp = String(localized: "quickVault.expand.help", defaultValue: "Open this place in the main window (⌘↩)")
    static let noLines = String(localized: "quickVault.noLines", defaultValue: "Nothing here yet")
    /// The island while locked, when the shortcut asked for the quick vault (board QuickVault-Locked).
    static let touchIDToOpen = String(localized: "quickVault.locked.touchID", defaultValue: "Touch ID to open Quick Vault")

    /// "Hidden from screen capture · closes when FX Vault locks" (board QuickVault-Place).
    static var footer: String {
        PlaceCopy.subline([
            NotesCopy.hiddenFromCapture,
            String(localized: "quickVault.closesOnLock", defaultValue: "closes when \(AppIdentity.windowTitle) locks"),
        ])
    }

    static func copy(_ name: String) -> String {
        String(localized: "quickVault.copy", defaultValue: "Copy \(name)")
    }

    static func copied(_ name: String) -> String {
        String(localized: "quickVault.copied", defaultValue: "Copied \(name)")
    }

    static let copyHelp = String(localized: "quickVault.copy.help", defaultValue: "Copy the value")
    static let copySecretHelp = String(
        localized: "quickVault.copy.secretHelp",
        defaultValue: "Copy the value. Asks for Touch ID or your master password."
    )
    static let copyMessage = String(
        localized: "quickVault.copy.message",
        defaultValue: "The value goes to the clipboard, which clears in \(Timeouts.clipboardClear.wholeSeconds) seconds."
    )
}
