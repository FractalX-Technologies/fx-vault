import SwiftUI
import UniformTypeIdentifiers
import VaultCore

/// The one table of the detail column (§10): Name, Value (masked with an eye toggle, "Value
/// missing", or plaintext for variables), Updated and Status, with the row actions Reveal, Copy,
/// Edit, Convert/Move…, Push on Next Sync (secrets), Revert and Delete.
struct ConfigTableView: View {
    @Bindable var viewModel: RepoDetailViewModel

    var body: some View {
        let rows = viewModel.rows
        Table(rows, selection: $viewModel.selection) {
            TableColumn(String(localized: "main.table.name", defaultValue: "Name")) { row in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: row.name)
                        .font(Theme.Typography.monospaced)
                        .strikethrough(row.isDeleted)
                        .lineLimit(1)
                    if let syncedName = row.syncedName {
                        Text(String(localized: "main.table.renamedFrom", defaultValue: "Renamed from \(syncedName)"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            }
            .width(min: Theme.Layout.tableNameMinWidth)
            TableColumn(String(localized: "main.table.value", defaultValue: "Value")) { row in
                MaskedValueCell(
                    display: viewModel.display(for: row),
                    onToggle: row.kind == .secret && row.hasValue && !row.isDeleted
                        ? { viewModel.toggleReveal(row.id) }
                        : nil
                )
            }
            .width(min: Theme.Layout.tableValueMinWidth)
            TableColumn(String(localized: "main.table.updated", defaultValue: "Updated")) { row in
                Text(row.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .width(min: Theme.Layout.tableDateMinWidth)
            TableColumn(String(localized: "main.table.status", defaultValue: "Status")) { row in
                StatusChip(status: row.status)
            }
            .width(min: Theme.Layout.tableStatusMinWidth)
        }
        .contextMenu(forSelectionType: ConfigItemID.self) { ids in
            if let id = ids.first, ids.count == 1, let row = rows.first(where: { $0.id == id }) {
                ConfigRowActions(row: row, viewModel: viewModel)
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                viewModel.edit(row)
            }
        }
        // ⌘V is handled by the whole detail column (RepoDetailScreen), not only the table.
        .overlay {
            if rows.isEmpty {
                EmptyStateView(
                    systemImage: viewModel.kind == .secret ? "key" : "textformat",
                    title: viewModel.kind == .secret
                        ? String(localized: "main.table.empty.secrets", defaultValue: "No secrets")
                        : String(localized: "main.table.empty.variables", defaultValue: "No variables"),
                    message: viewModel.canEdit
                        ? String(
                            localized: "main.table.empty.pasteMessage",
                            defaultValue: "Add one, paste KEY=value lines with ⌘V, or import a .env file."
                        )
                        : String(localized: "main.table.empty.readOnly", defaultValue: "Nothing in this scope.")
                ) {
                    if viewModel.canEdit {
                        Button(String(localized: "main.detail.pasteMultiple", defaultValue: "Paste Multiple…")) {
                            viewModel.pasteMultiple()
                        }
                    }
                }
            }
        }
    }
}

/// Reveal, Copy, Edit (or Fill Value), Convert/Move…, Push on Next Sync, Revert and Delete for
/// one row.
private struct ConfigRowActions: View {
    let row: ConfigRowModel
    let viewModel: RepoDetailViewModel

    var body: some View {
        if row.kind == .secret, row.hasValue, !row.isDeleted {
            Button(viewModel.isRevealed(row.id) ? MaskedValueCell.hideTitle : MaskedValueCell.revealTitle) {
                viewModel.toggleReveal(row.id)
            }
        }
        Button(String(localized: "main.table.copy", defaultValue: "Copy Value")) {
            viewModel.copy(row.id)
        }
        .disabled(!row.hasValue)
        Divider()
        Button(row.hasValue
            ? String(localized: "main.table.edit", defaultValue: "Edit…")
            : String(localized: "main.table.fill", defaultValue: "Fill Value…")) {
            viewModel.edit(row)
        }
        .disabled(!viewModel.canEdit || row.isDeleted)
        Button(String(localized: "main.table.move", defaultValue: "Convert or Move…")) {
            viewModel.move(row)
        }
        .disabled(!viewModel.canEdit || row.isDeleted)
        if row.canPushOnNextSync {
            Button(String(localized: "main.table.pushOnNextSync", defaultValue: "Push on Next Sync")) {
                viewModel.pushOnNextSync(row)
            }
            .disabled(!viewModel.canEdit)
        }
        if row.canRevert {
            Button(String(localized: "main.table.revert", defaultValue: "Revert")) {
                viewModel.revert(row)
            }
        }
        Divider()
        Button(String(localized: "main.table.delete", defaultValue: "Delete…"), role: .destructive) {
            viewModel.requestDeletion(row)
        }
        .disabled(!viewModel.canEdit || row.isDeleted)
    }
}
