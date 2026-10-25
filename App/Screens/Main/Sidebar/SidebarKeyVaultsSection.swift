import SwiftUI
import VaultCore

/// Azure in the sidebar (1.0; flat until the subscriptions of 1g): the Key Vaults of their own
/// (Connect Azure imports them) with ``KeyVaultContextMenu``; hidden when there is none or the
/// search matches none.
struct SidebarKeyVaultsSection: View {
    let sidebar: SidebarViewModel

    var body: some View {
        let vaults = sidebar.visibleKeyVaults
        if !vaults.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                SidebarSectionHeader(SidebarCopy.azureSection)
                ForEach(vaults) { vault in
                    SidebarTreeRow(
                        level: 0,
                        systemImage: vault.provider.symbolName,
                        title: vault.title,
                        isSelected: sidebar.selectedKeyVaultID == vault.id,
                        accessibilityID: AccessibilityID.Main.keyVault(vault.title)
                    ) {
                        sidebar.selectedKeyVaultID = vault.id
                    } trailing: {
                        if vault.valueMissingCount > 0 {
                            SidebarCount(value: vault.valueMissingCount, help: DestinationCopy.valueMissingHelp(vault.valueMissingCount))
                        }
                        if vault.pendingCount > 0 {
                            SidebarPendingDot()
                        }
                    }
                    .help(vault.subtitle)
                    .contextMenu {
                        KeyVaultContextMenu(vault: vault, sidebar: sidebar)
                    }
                }
            }
        }
    }
}

/// A Key Vault of its own's actions (its sidebar row, its detail's Actions button).
struct KeyVaultContextMenu: View {
    let vault: DestinationModel
    let sidebar: SidebarViewModel

    var body: some View {
        Button(DestinationCopy.removeMenu, role: .destructive) {
            sidebar.pendingKeyVaultRemoval = vault
        }
    }
}
