import SwiftUI
import VaultCore

/// AZURE KEY VAULT in the sidebar (1.0): the Key Vaults of their own (Connect Azure imports
/// them), one ``DestinationRow`` each; hidden when there is none or the search matches none.
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
                }
            }
        }
    }
}
