import SwiftUI
import VaultCore

/// AZURE KEY VAULT in the sidebar (1.0): the Key Vaults of their own (Connect Azure imports
/// them), one ``DestinationRow`` each with ``KeyVaultContextMenu``; hidden when there is none or
/// the search matches none.
struct SidebarKeyVaultsSection: View {
    let sidebar: SidebarViewModel

    var body: some View {
        let vaults = sidebar.visibleKeyVaults
        if !vaults.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                SectionLabel(MainCopy.azureSection)
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.bottom, Theme.Spacing.xSmall)
                ForEach(vaults) { vault in
                    Button {
                        sidebar.selectedKeyVaultID = vault.id
                    } label: {
                        DestinationRow(destination: vault, isSelected: sidebar.selectedKeyVaultID == vault.id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.Main.keyVault(vault.title))
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
