import SwiftUI
import UniformTypeIdentifiers
import VaultCore

/// The one table of the detail column (§10; mockup Main): Name (with the Linked chip of a linked
/// copy, v0.4.1), Value (masked with an eye toggle, "Value missing", or plaintext for variables),
/// Updated and Status, with the row actions Reveal, Copy, Edit, Convert/Move…, Copy To, linked
/// copies, Push on Next Sync (secrets), Revert and Delete.
///
/// A native `Table` (selection, keyboard, context menus, double-click to edit) styled with
/// `.fxTable()`: a card with 16 pt corners, 52 pt rows, mono names and timestamps, mono
/// uppercase column titles.
struct ConfigTableView: View {
    @Bindable var viewModel: RepoDetailViewModel

    var body: some View {
        let rows = viewModel.rows
        Table(rows, selection: $viewModel.selection) {
            TableColumn(Self.header(String(localized: "main.table.name", defaultValue: "Name"))) { row in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    HStack(spacing: Theme.Spacing.smallMinus) {
                        TableNameText(name: row.name, isDeleted: row.isDeleted)
                        if row.isLinked {
                            LinkedChip(row: row, viewModel: viewModel)
                        }
                    }
                    if let syncedName = row.syncedName {
                        Text(String(localized: "main.table.renamedFrom", defaultValue: "Renamed from \(syncedName)"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.mutedText)
                            .lineLimit(1)
                    }
                }
                .fxTableCell()
            }
            .width(min: Theme.Layout.tableNameMinWidth, ideal: Theme.Layout.tableNameIdealWidth)
            TableColumn(Self.header(String(localized: "main.table.value", defaultValue: "Value"))) { row in
                MaskedValueCell(
                    display: viewModel.display(for: row),
                    onToggle: row.kind == .secret && row.hasValue && !row.isDeleted
                        ? { viewModel.toggleReveal(row.id) }
                        : nil
                )
                .fxTableCell()
            }
            .width(min: Theme.Layout.tableValueMinWidth)
            TableColumn(Self.header(String(localized: "main.table.updated", defaultValue: "Updated"))) { row in
                TableMetaText(Self.updatedText(row.updatedAt))
                    .help(row.updatedAt.formatted(date: .complete, time: .shortened))
                    .fxTableCell()
            }
            .width(Theme.Layout.tableDateMinWidth)
            TableColumn(Self.header(String(localized: "main.table.status", defaultValue: "Status"))) { row in
                StatusChip(status: row.status)
                    .fxTableCell()
            }
            .width(Theme.Layout.tableStatusMinWidth)
        }
        .fxTable()
        .contextMenu(forSelectionType: ConfigItemID.self) { ids in
            if let id = ids.first, ids.count == 1, let row = rows.first(where: { $0.id == id }) {
                ConfigRowActions(row: row, viewModel: viewModel)
            } else if ids.count > 1 {
                ConfigSelectionMenu(rows: viewModel.rows(for: ids), viewModel: viewModel)
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                viewModel.edit(row)
            }
        }
        // ⌘V is handled by the whole detail column (RepoDetailScreen), not only the table.
        .onDeleteCommand {
            viewModel.deleteSelection()
        }
        // ⌘C copies the selected items (v0.4.0): ⌘V in another scope or repository pastes them as
        // linked copies (v0.4.1). Disabled (the Copy menu item greyed) with nothing selected.
        .onCommand(#selector(NSText.copy(_:)), perform: viewModel.selection.isEmpty ? nil : { viewModel.copySelection() })
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
                        .fxButtonStyle(.outline)
                    }
                }
            }
        }
    }

    /// A column title in the section-label style (mono 11, uppercase, +0.08em, subtle). `Table`
    /// takes a `Text`, so the case is applied to the string (in the current locale) rather than
    /// with `textCase`.
    static func header(_ title: String) -> Text {
        let style = Theme.TextStyle.sectionLabel
        return Text(verbatim: title.uppercased(with: .current))
            .font(style.font)
            .tracking(style.tracking)
            .foregroundStyle(Theme.Colors.subtleText)
    }

    /// "Oct 15 · 10:42" (mockup Main) for this year; only the date ("Jan 1, 2001") for dates
    /// outside the current year, so the cell fits its fixed column. The full timestamp is in the
    /// cell's help.
    static func updatedText(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        guard calendar.isDate(date, equalTo: now, toGranularity: .year) else {
            return date.formatted(.dateTime.month(.abbreviated).day().year())
        }
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        let time = date.formatted(date: .omitted, time: .shortened)
        return String(localized: "main.table.updatedAt", defaultValue: "\(day) · \(time)")
    }
}

/// "Copy To ›" (v0.4.0): the repository's other scopes, the ones this account may not change
/// listed disabled, then "Another Repository…" (v0.4.1). The copies are pending adds there,
/// values re-encrypted in the vault, linked to their sources.
struct CopyToMenu: View {
    let title: String
    let rows: [ConfigRowModel]
    let viewModel: RepoDetailViewModel
    /// A trailing chevron, for the selection bar's pill (a context menu draws its own arrow).
    var showsChevron = false

    var body: some View {
        let targets = viewModel.copyTargets
        Menu {
            ForEach(targets) { target in
                Button(target.title) {
                    viewModel.copy(rows, to: target)
                }
                .disabled(!target.isEditable)
            }
            if !targets.isEmpty {
                Divider()
            }
            Button(String(localized: "main.table.copyTo.otherRepository", defaultValue: "Another Repository…")) {
                viewModel.copyToOtherRepository(rows)
            }
        } label: {
            if showsChevron {
                HStack(spacing: Theme.Spacing.smallMinus) {
                    Text(title)
                    Image(systemName: "chevron.down")
                        .font(Theme.Typography.monoLabel)
                        .accessibilityHidden(true)
                }
            } else {
                Text(title)
            }
        }
        .disabled(rows.isEmpty)
    }
}

/// Copy To, Push on Next Sync, Revert and Delete… for several rows (v0.4.0), each for the rows it
/// applies to.
private struct ConfigSelectionMenu: View {
    let rows: [ConfigRowModel]
    let viewModel: RepoDetailViewModel

    var body: some View {
        let actions = ConfigSelectionActionsModel(rows: rows)
        CopyToMenu(
            title: String(localized: "main.table.several.copyTo", defaultValue: "Copy \(actions.deletable.count) Items To"),
            rows: actions.deletable,
            viewModel: viewModel
        )
        Divider()
        if !actions.pushable.isEmpty {
            Button(String(localized: "main.table.several.pushOnNextSync", defaultValue: "Push \(actions.pushable.count) on Next Sync")) {
                viewModel.pushOnNextSync(actions.pushable)
            }
            .disabled(!viewModel.canEdit)
        }
        if !actions.revertible.isEmpty {
            Button(String(localized: "main.table.several.revert", defaultValue: "Revert \(actions.revertible.count)")) {
                viewModel.revert(actions.revertible)
            }
        }
        Divider()
        Button(String(localized: "main.table.several.delete", defaultValue: "Delete \(actions.deletable.count)…"), role: .destructive) {
            viewModel.requestDeletion(of: actions.deletable)
        }
        .disabled(!viewModel.canEdit || actions.deletable.isEmpty)
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
        if !row.isDeleted {
            CopyToMenu(title: String(localized: "main.table.copyTo", defaultValue: "Copy To"), rows: [row], viewModel: viewModel)
        }
        if row.isLinked {
            Button(String(localized: "main.table.linked.show", defaultValue: "Show Linked Copies")) {
                viewModel.showLinkedCopies(of: row)
            }
            Button(String(localized: "main.table.linked.unlink", defaultValue: "Unlink")) {
                viewModel.unlink(row)
            }
        }
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
