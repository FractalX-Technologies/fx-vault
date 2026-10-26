import SwiftUI
import VaultCore

/// Azure in the sidebar (1.0 D6c6; board Main2-Repository): each subscription with its Key Vaults
/// of their own (Connect Azure imports them) under it, ``KeyVaultContextMenu`` on a vault. A vault
/// whose subscription isn't saved yet (imported before) sits directly under Azure until a
/// Refresh finds it. Hidden when there is none or the search matches none.
struct SidebarKeyVaultsSection: View {
    let sidebar: SidebarViewModel

    var body: some View {
        let azure = sidebar.visibleAzure
        if !azure.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                SidebarSectionHeader(SidebarCopy.azureSection)
                ForEach(azure.ungrouped) { vault in
                    KeyVaultRow(vault: vault, level: 0, sidebar: sidebar)
                }
                ForEach(azure.subscriptions) { group in
                    let isExpanded = sidebar.isExpanded(subscription: group.id)
                    SidebarTreeRow(
                        level: 0,
                        isExpanded: isExpanded,
                        systemImage: Theme.Symbols.subscription,
                        title: group.subscription.name,
                        titleStyle: .sans,
                        isSelected: false,
                        onToggle: { sidebar.toggle(subscription: group.id) }
                    ) {
                        sidebar.toggle(subscription: group.id)
                    } trailing: {
                        EmptyView()
                    }
                    if isExpanded {
                        ForEach(group.vaults) { vault in
                            KeyVaultRow(vault: vault, level: 1, sidebar: sidebar)
                        }
                    }
                }
            }
        }
    }
}

/// One Key Vault of its own: its count of secrets without a value, its pending dot, its menu.
private struct KeyVaultRow: View {
    let vault: DestinationModel
    let level: Int
    let sidebar: SidebarViewModel

    var body: some View {
        SidebarTreeRow(
            level: level,
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

/// The Azure section's rows (1.0 D6c6). Pure, so the grouping is tested without the window.
struct SidebarAzureModel: Equatable {
    /// Vaults without a saved subscription, directly under Azure, in the observed order.
    let ungrouped: [DestinationModel]
    /// One group per subscription, by name; each keeps its vaults in the observed order.
    let subscriptions: [SidebarSubscriptionModel]

    init(vaults: [DestinationModel]) {
        ungrouped = vaults.filter { $0.subscription == nil }
        var groups: [UUID: SidebarSubscriptionModel] = [:]
        for vault in vaults {
            guard let subscription = vault.subscription else { continue }
            // Two vaults may have saved one subscription under different names: the last one wins.
            let vaults = (groups[subscription.id]?.vaults ?? []) + [vault]
            groups[subscription.id] = SidebarSubscriptionModel(subscription: subscription, vaults: vaults)
        }
        subscriptions = groups.values.sorted { lhs, rhs in
            let byName = lhs.subscription.name.localizedStandardCompare(rhs.subscription.name)
            return byName == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : byName == .orderedAscending
        }
    }

    var isEmpty: Bool {
        ungrouped.isEmpty && subscriptions.isEmpty
    }
}

/// One Azure subscription and its vaults in the sidebar.
struct SidebarSubscriptionModel: Identifiable, Equatable {
    let subscription: KeyVaultSubscriptionModel
    let vaults: [DestinationModel]

    var id: UUID {
        subscription.id
    }
}
