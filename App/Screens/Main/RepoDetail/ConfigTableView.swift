import SwiftUI
import UniformTypeIdentifiers
import VaultCore

/// The one table of the detail column (§10; mockup Main): Name (with the Linked chip of a linked
/// copy, v0.4.1), Value (masked with an eye toggle, "Value missing", or plaintext for variables),
/// Updated and, for a repository scope, Status. The row and selection menus come from the
/// owner: a repository scope (``ConfigRowActions``) or, v0.7.0, a folder, which has no sync
/// state.
///
/// A native `Table` (selection, keyboard, context menus, double-click to edit) styled with
/// `.fxTable()`: a card with 16 pt corners, 52 pt rows, mono names and timestamps, mono
/// uppercase column titles.
struct ConfigTableView<Model: ConfigTableModel, RowMenu: View, SelectionMenu: View>: View {
    @Bindable var viewModel: Model
    let rowMenu: (ConfigRowModel) -> RowMenu
    let selectionMenu: ([ConfigRowModel]) -> SelectionMenu
    /// The empty state's message when items can be added.
    var emptyMessage = String(
        localized: "main.table.empty.pasteMessage",
        defaultValue: "Add one, paste KEY=value lines with ⌘V, or import a .env file."
    )

    init(
        viewModel: Model,
        emptyMessage: String? = nil,
        @ViewBuilder rowMenu: @escaping (ConfigRowModel) -> RowMenu,
        @ViewBuilder selectionMenu: @escaping ([ConfigRowModel]) -> SelectionMenu
    ) {
        self.viewModel = viewModel
        self.rowMenu = rowMenu
        self.selectionMenu = selectionMenu
        if let emptyMessage {
            self.emptyMessage = emptyMessage
        }
    }

    var body: some View {
        let rows = viewModel.tableRows
        Group {
            if viewModel.showsSyncStatus {
                Table(rows, selection: $viewModel.selection) {
                    commonColumns
                    TableColumn(Self.header(String(localized: "main.table.status", defaultValue: "Status"))) { row in
                        Group {
                            if row.inherited != nil {
                                Text(PlaceCopy.inherited)
                                    .fxTextStyle(.caption)
                                    .foregroundStyle(Theme.Colors.mutedText)
                            } else {
                                ConfigStatusLabel(row: row, heldHelp: viewModel.heldHelp(for: row))
                            }
                        }
                        .fxTableCell()
                    }
                    .width(Theme.Layout.tableStatusMinWidth)
                }
            } else {
                Table(rows, selection: $viewModel.selection) {
                    commonColumns
                }
            }
        }
        .fxTable()
        // An inherited row is read only: no menu, no edit (B7a).
        .contextMenu(forSelectionType: ConfigItemID.self) { ids in
            if let id = ids.first, ids.count == 1, let row = rows.first(where: { $0.id == id }), row.inherited == nil {
                rowMenu(row)
            } else if ids.count > 1, !viewModel.rows(for: ids).isEmpty {
                selectionMenu(viewModel.rows(for: ids))
            }
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }), row.inherited == nil {
                viewModel.edit(row)
            }
        }
        // ⌘V is handled by the whole detail column, not only the table.
        .onDeleteCommand {
            viewModel.deleteSelection()
        }
        // ⌘C copies the selected items (v0.4.0): ⌘V in another scope, repository or folder pastes
        // them as linked copies (v0.4.1, v0.7.0). Disabled with nothing of the place's own selected.
        .onCommand(#selector(NSText.copy(_:)), perform: viewModel.canCopySelection ? { viewModel.copySelection() } : nil)
        .overlay {
            if rows.isEmpty {
                EmptyStateView(
                    systemImage: viewModel.kind.symbolName,
                    title: viewModel.kind == .secret
                        ? String(localized: "main.table.empty.secrets", defaultValue: "No secrets")
                        : String(localized: "main.table.empty.variables", defaultValue: "No variables"),
                    message: viewModel.canEdit
                        ? emptyMessage
                        : String(localized: "main.table.empty.readOnly", defaultValue: "Nothing in this scope.")
                ) {
                    if viewModel.canEdit {
                        Button(PlaceCopy.pasteMultiple) {
                            viewModel.pasteMultiple()
                        }
                        .fxButtonStyle(.outline)
                    }
                }
            }
        }
    }

    /// Name, Value and Updated (every table); Status follows for a repository scope.
    @TableColumnBuilder<ConfigRowModel, Never>
    private var commonColumns: some TableColumnContent<ConfigRowModel, Never> {
        TableColumn(Self.header(String(localized: "main.table.name", defaultValue: "Name"))) { row in
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                HStack(spacing: Theme.Spacing.smallMinus) {
                    TableNameText(name: row.name, isDeleted: row.isDeleted, isMuted: row.inherited != nil)
                    if row.isLinked {
                        LinkedChip(row: row, viewModel: viewModel)
                    }
                }
                if let inherited = row.inherited {
                    TableMetaText(inherited.scope)
                        .lineLimit(1)
                } else if let syncedName = row.syncedName {
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
                file: row.file,
                onToggle: row.kind == .secret && row.hasValue && !row.isDeleted && row.inherited == nil
                    ? { viewModel.toggleReveal(row.id) }
                    : nil
            )
            .fxTableCell()
        }
        .width(min: Theme.Layout.tableValueMinWidth)
        TableColumn(Self.header(String(localized: "main.table.updated", defaultValue: "Updated"))) { row in
            // An organization item added in FX Vault has no GitHub date yet.
            let updatedAt = row.inherited.map(\.updatedAt) ?? row.updatedAt
            TableMetaText(updatedAt.map { ConfigTableFormat.updatedText($0) } ?? "—")
                .help(updatedAt?.formatted(date: .complete, time: .shortened) ?? "")
                .fxTableCell()
        }
        .width(Theme.Layout.tableDateMinWidth)
    }

    /// A column title in the section-label style.
    static func header(_ title: String) -> Text {
        ConfigTableFormat.header(title)
    }
}

extension ConfigTableView where Model == RepoDetailViewModel, RowMenu == ConfigRowActions, SelectionMenu == ConfigSelectionMenu {
    /// The table of a repository scope, with its sync actions.
    init(viewModel: RepoDetailViewModel) {
        self.init(viewModel: viewModel) { row in
            ConfigRowActions(row: row, viewModel: viewModel)
        } selectionMenu: { rows in
            ConfigSelectionMenu(rows: rows, viewModel: viewModel)
        }
    }
}

/// A row's sync status (or the Held chip, v0.9.0), then "· Overrides example-org" when an
/// organization item of the same name reaches the repository and this one wins (B7a; board
/// Place-Table).
private struct ConfigStatusLabel: View {
    let row: ConfigRowModel
    let heldHelp: String

    var body: some View {
        let overridesHelp = row.overrides.map(PlaceCopy.overridesHelp) ?? ""
        HStack(spacing: Theme.Spacing.smallMinus) {
            if row.isHeld {
                StatusChip(title: HeldShareCopy.chip, tone: .warning)
                    .help(heldHelp)
            } else {
                StatusDotLabel(status: row.status)
                    .help(overridesHelp)
            }
            if let organization = row.overrides {
                Text(PlaceCopy.overrides(organization))
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
                    .help(overridesHelp)
            }
        }
    }
}

/// The table's text formats, shared by every ``ConfigTableView``.
enum ConfigTableFormat {
    /// A column title as the boards draw it (Main2, Org-Visibility): 12 pt medium, sentence case,
    /// muted.
    static func header(_ title: String) -> Text {
        Text(verbatim: title)
            .font(Theme.Typography.caption.weight(.medium))
            .foregroundStyle(Theme.Colors.mutedText)
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
/// listed disabled, the folders (v0.7.0), the repository's destinations (v0.8.0), then "Another
/// Repository…" (v0.4.1). Copies into a
/// scope are pending adds there and copies into a folder are saved at once; values are
/// re-encrypted in the vault and every copy is linked to its source.
struct CopyToMenu<Model: ConfigTableModel>: View {
    let title: String
    let rows: [ConfigRowModel]
    let viewModel: Model
    /// A trailing chevron, for the selection bar's pill (a context menu draws its own arrow).
    var showsChevron = false

    var body: some View {
        let targets = viewModel.scopeCopyTargets
        let folders = viewModel.folderCopyTargets
        let destinations = viewModel.destinationCopyTargets
        Menu {
            ForEach(targets) { target in
                Button(target.title) {
                    viewModel.copy(rows, to: target)
                }
                .disabled(!target.isEditable)
            }
            if !folders.isEmpty {
                if !targets.isEmpty {
                    Divider()
                }
                Section(String(localized: "main.table.copyTo.folders", defaultValue: "Folders")) {
                    ForEach(folders) { target in
                        Button(target.title) {
                            viewModel.copy(rows, to: target)
                        }
                    }
                }
            }
            if !destinations.isEmpty {
                if !targets.isEmpty || !folders.isEmpty {
                    Divider()
                }
                Section(String(localized: "main.table.copyTo.destinations", defaultValue: "Destinations")) {
                    ForEach(destinations) { target in
                        Button(target.title) {
                            viewModel.copy(rows, to: target)
                        }
                    }
                }
            }
            if !targets.isEmpty || !folders.isEmpty || !destinations.isEmpty {
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
struct ConfigSelectionMenu: View {
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
struct ConfigRowActions: View {
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
            CopyToMenu(title: PlaceCopy.copyTo, rows: [row], viewModel: viewModel)
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
