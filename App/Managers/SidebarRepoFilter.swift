import Foundation

/// Which repositories the GitHub tree lists (the sidebar's filter menu).
enum SidebarRepoFilter: String, CaseIterable, Identifiable {
    /// Only the repositories in the vault, like Azure lists only the vaults added to FX Vault.
    case added
    /// Every repository gh lists too, the rest behind each owner's "Show N more".
    case all

    var id: String {
        rawValue
    }
}
