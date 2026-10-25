import Foundation
import VaultCore

/// Texts the main window's tree and toolbar path share (1.0).
enum MainCopy {
    /// The sidebar section of the GitHub accounts, and the first step of their path.
    static let gitHubSection = String(localized: "main.sidebar.github", defaultValue: "GitHub")
    /// The sidebar section of the Key Vaults of their own, and the first step of their path.
    static let azureSection = DestinationProvider.azureKeyVault.title
}
