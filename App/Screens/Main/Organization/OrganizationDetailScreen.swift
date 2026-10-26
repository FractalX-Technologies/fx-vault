import SwiftUI
import VaultCore
import VaultData

/// Column 3 for an imported organization (1.0; board Org-Visibility): the header (the login,
/// "Organization · counts", ⋯ More) and the table Name | Kind | Value | Visibility | Status |
/// Updated.
struct OrganizationDetailScreen: View {
    @Bindable var viewModel: OrganizationDetailViewModel
    let main: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumPlus) {
            header
            if viewModel.rows.isEmpty {
                Text(OrganizationCopy.empty)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            } else {
                OrganizationItemsTable(viewModel: viewModel)
            }
        }
        .fxPlaceColumn()
        .errorAlert($viewModel.alert)
        .confirmationDialog(
            ConfigDeletionModel.title(count: viewModel.pendingDeletion?.count ?? 0),
            isPresented: Binding(
                get: { viewModel.pendingDeletion != nil },
                set: { if !$0 { viewModel.pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: viewModel.pendingDeletion
        ) { rows in
            Button(ConfigDeletionModel.confirmTitle(count: rows.count), role: .destructive) {
                viewModel.confirmDeletion()
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { rows in
            Text(ConfigDeletionModel.message(
                syncedNames: rows.filter(\.isOnGitHub).map(\.name),
                unsyncedCount: rows.filter { !$0.isOnGitHub }.count
            ))
        }
    }

    /// The login, "Organization · counts" and ⋯ More: New Secret, New Variable, Remove from
    /// Vault… (board Org-Visibility; Refresh arrives with B7).
    private var header: some View {
        PlaceHeader(title: viewModel.organization?.login ?? "", subline: viewModel.subline) {
            ForEach(ConfigKind.allCases, id: \.self) { kind in
                Button(PlaceCopy.newItem(kind)) {
                    viewModel.add(kind)
                }
                .accessibilityIdentifier(AccessibilityID.Main.organizationAdd(kind.rawValue))
            }
            if let organization = viewModel.organization {
                Divider()
                Button(OrganizationCopy.remove, role: .destructive) {
                    main.sidebar.requestRemoval(organization)
                }
            }
        }
    }
}

/// Names in mono, a masked value or "Value missing", who can use the item, its sync status and
/// when GitHub last changed it; the row menu edits, deletes, reverts and copies.
private struct OrganizationItemsTable: View {
    @Bindable var viewModel: OrganizationDetailViewModel

    var body: some View {
        Table(viewModel.rows, selection: $viewModel.selection) {
            TableColumn(ConfigTableFormat.header(String(localized: "main.table.name", defaultValue: "Name"))) { row in
                TableNameText(name: row.name, isDeleted: row.syncStatus == .deleted)
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
            TableColumn(ConfigTableFormat.header(String(localized: "main.table.status", defaultValue: "Status"))) { row in
                StatusDotLabel(status: row.syncStatus)
                    .fxTableCell()
            }
            .width(Theme.Layout.tableStatusMinWidth)
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
        .contextMenu(forSelectionType: ConfigItemID.self) { ids in
            OrganizationRowActions(rows: viewModel.rows(for: ids), viewModel: viewModel)
        } primaryAction: { ids in
            if ids.count == 1, let row = viewModel.rows(for: ids).first {
                viewModel.edit(row)
            }
        }
        .onDeleteCommand {
            viewModel.requestDeletion(of: viewModel.rows(for: viewModel.selection))
        }
        .accessibilityIdentifier(AccessibilityID.Main.organizationTable)
    }
}

/// Copy Value and Edit… for one row; Revert and Delete… for every selected row that allows it.
private struct OrganizationRowActions: View {
    let rows: [OrgItemModel]
    let viewModel: OrganizationDetailViewModel

    var body: some View {
        if rows.count == 1, let row = rows.first {
            Button(String(localized: "main.table.copy", defaultValue: "Copy Value")) {
                viewModel.copy(row)
            }
            .disabled(!row.hasValue)
            Divider()
            Button(String(localized: "main.table.edit", defaultValue: "Edit…")) {
                viewModel.edit(row)
            }
            .disabled(row.syncStatus == .deleted)
        }
        let revertible = rows.filter(\.canRevert)
        if !revertible.isEmpty {
            Button(revertible.allSatisfy { $0.syncStatus == .modified }
                ? OrganizationCopy.revertAccess
                : String(localized: "main.table.revert", defaultValue: "Revert")) {
                    viewModel.revert(revertible)
                }
        }
        if rows.contains(where: { $0.syncStatus != .deleted }) {
            Divider()
            Button(String(localized: "main.table.delete", defaultValue: "Delete…"), role: .destructive) {
                viewModel.requestDeletion(of: rows)
            }
        }
    }
}

/// Column 3 for an organization that is not in the vault: what Import reads, and Import.
struct OrganizationImportPromptView: View {
    let owner: SidebarOwnerModel
    let sidebar: SidebarViewModel

    var body: some View {
        EmptyStateView(systemImage: Theme.Symbols.organization, title: owner.login, message: OrganizationCopy.importMessage) {
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
