import Foundation
import VaultCore

/// Texts the main window's tree and toolbar path share (1.0).
enum MainCopy {
    /// The sidebar section of the GitHub accounts, and the first step of their path.
    static let gitHubSection = String(localized: "main.sidebar.github", defaultValue: "GitHub")
    /// The Key Vaults of their own as a group (Sync, Connect); the sidebar and the toolbar path
    /// say "Azure" (``SidebarCopy/azureSection``).
    static let azureSection = DestinationProvider.azureKeyVault.title
    /// File › New Repository… and an owner's menu in the sidebar.
    static let newRepository = String(localized: "menu.file.newRepository", defaultValue: "New Repository…")

    /// The detail with nothing selected (1.0 D6c2, board Main2-Home).
    static let homeTitle = String(localized: "main.home.title", defaultValue: "Choose a place")

    static func homePendingChanges(_ count: Int) -> String {
        guard count > 0 else {
            return String(localized: "main.home.nothingPending", defaultValue: "No pending changes")
        }
        return String(inflected: AttributedString(
            localized: "main.home.pending",
            defaultValue: "^[\(count) pending change](inflect: true)"
        ))
    }

    /// The banner while the recovery key was never confirmed as saved (board Main2-Home).
    static let recoveryKeyNotSaved = String(localized: "main.recoveryBanner", defaultValue: "Your recovery key wasn't saved")
    static let createNewRecoveryKey = String(localized: "main.recoveryBanner.createKey", defaultValue: "Create New Key…")
}
