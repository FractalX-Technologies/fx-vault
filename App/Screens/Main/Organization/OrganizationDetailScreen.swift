import SwiftUI
import VaultCore
import VaultData

/// Column 3 for an imported organization (1.0; mockup Org-Visibility): ORGANIZATION, the login
/// in the large title with the counts and the Read only tag, Remove from Vault, and the table
/// Name | Kind | Value | Visibility | Updated.
struct OrganizationDetailScreen: View {
    let viewModel: OrganizationDetailViewModel
    let main: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.largePlus) {
            header
            if viewModel.rows.isEmpty {
                Text(OrganizationCopy.empty)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            } else {
                OrganizationItemsTable(rows: viewModel.rows)
            }
        }
        .padding(.horizontal, Theme.Spacing.xxLargePlus)
        .padding(.vertical, Theme.Spacing.xLargePlus)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
                SectionLabel(OrganizationCopy.eyebrow)
                Text(verbatim: viewModel.organization?.login ?? "")
                    .fxTextStyle(.largeTitle)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: Theme.Spacing.small) {
                    Text(viewModel.counts)
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.mutedText)
                    StatusChip.tag(OrganizationCopy.readOnlyTag)
                        .help(OrganizationCopy.readOnlyHelp)
                }
                .padding(.top, Theme.Spacing.xSmall)
            }
            Spacer(minLength: 0)
            if let organization = viewModel.organization {
                Button(OrganizationCopy.remove, role: .destructive) {
                    main.sidebar.requestRemoval(organization)
                }
                .fxButtonStyle(.outline)
            }
        }
    }
}

/// The read-only table: names in mono, a masked value or "Value missing", who can use the item
/// and when GitHub last changed it.
private struct OrganizationItemsTable: View {
    let rows: [OrgItemModel]

    var body: some View {
        Table(rows) {
            TableColumn(ConfigTableFormat.header(String(localized: "main.table.name", defaultValue: "Name"))) { row in
                TableNameText(name: row.name)
                    .fxTableCell()
            }
            TableColumn(ConfigTableFormat.header(OrganizationCopy.kind)) { row in
                TableMetaText(row.kind.editorTitle)
                    .fxTableCell()
            }
            TableColumn(ConfigTableFormat.header(String(localized: "main.table.value", defaultValue: "Value"))) { row in
                MaskedValueCell(display: row.hasValue ? .masked : .missing, onToggle: nil)
                    .fxTableCell()
            }
            TableColumn(ConfigTableFormat.header(OrganizationCopy.visibility)) { row in
                TableMetaText(row.visibility.title(selectedCount: row.selectedRepositoryCount))
                    .fxTableCell()
            }
            TableColumn(ConfigTableFormat.header(String(localized: "main.table.updated", defaultValue: "Updated"))) { row in
                Group {
                    if let updated = row.remoteUpdatedAt {
                        TableMetaText(ConfigTableFormat.updatedText(updated))
                            .help(updated.formatted(date: .complete, time: .shortened))
                    }
                }
                .fxTableCell()
            }
        }
        .fxTable()
        .accessibilityIdentifier(AccessibilityID.Main.organizationTable)
    }
}

/// Column 3 for an organization that is not in the vault: what Import reads, and Import.
struct OrganizationImportPromptView: View {
    let owner: SidebarOwnerModel
    let sidebar: SidebarViewModel

    var body: some View {
        EmptyStateView(systemImage: "building.2", title: owner.login, message: OrganizationCopy.importMessage) {
            if sidebar.isBusy(owner) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(OrganizationCopy.importButton) {
                    Task { await sidebar.importOrganization(owner) }
                }
                .fxButtonStyle(.primary, size: .large)
                .disabled(!sidebar.canImportOrganization(owner))
                .accessibilityIdentifier(AccessibilityID.Main.importOrganization)
            }
        }
    }
}
