import SwiftUI
import VaultCore
import VaultData

/// Column 3 for a folder (v0.7.0): FOLDER and the folder's name, the "Never on GitHub" tag, the
/// folder's actions, the Secrets | Variables pill with the add actions (or the selection's
/// actions), and the table without the Status column.
struct FolderDetailScreen: View {
    @Bindable var viewModel: FolderDetailViewModel
    let main: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.largePlus) {
            FolderDetailHeader(viewModel: viewModel, main: main)
            FolderDetailControls(viewModel: viewModel)
            ConfigTableView(
                viewModel: viewModel,
                emptyMessage: String(
                    localized: "folder.table.empty",
                    defaultValue: "Add one, paste KEY=value lines with ⌘V, import a .env file, or copy items here from a repository."
                )
            ) { row in
                FolderRowActions(row: row, viewModel: viewModel)
            } selectionMenu: { rows in
                FolderSelectionMenu(rows: rows, viewModel: viewModel)
            }
            if let notice = viewModel.notice {
                Text(notice)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        }
        .padding(.horizontal, Theme.Spacing.xxLargePlus)
        .padding(.vertical, Theme.Spacing.xLargePlus)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onPasteCommand(of: [.plainText], validator: viewModel.validatePaste) { providers in
            Task { await viewModel.handlePaste(providers) }
        }
        .errorAlert($viewModel.alert)
        .confirmationDialog(
            FolderCopy.deleteItemsTitle(count: viewModel.pendingDeletion?.count ?? 0),
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: viewModel.pendingDeletion
        ) { rows in
            Button(FolderCopy.deleteItemsConfirm(count: rows.count), role: .destructive) {
                viewModel.confirmDeletion()
            }
        } message: { _ in
            Text(FolderCopy.deleteItemsMessage)
        }
        .modifier(ItemCopyConflictDialog(viewModel: viewModel))
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingDeletion != nil },
            set: { if !$0 { viewModel.pendingDeletion = nil } }
        )
    }
}

/// FOLDER, the name in the large title and the tag, then the folder's actions on the right (or
/// below when the column is narrow).
private struct FolderDetailHeader: View {
    let viewModel: FolderDetailViewModel
    let main: MainViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.large) {
                details
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                details
                actions
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            SectionLabel(FolderCopy.eyebrow)
            Text(verbatim: viewModel.folder?.name ?? "")
                .fxTextStyle(.largeTitle)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            StatusChip.tag(FolderCopy.localTag)
                .help(FolderCopy.localHelp)
                .padding(.top, Theme.Spacing.xSmall)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.large) {
            Button(FolderCopy.shareAsFile) {
                viewModel.shareAsFile()
            }
            .fxButtonStyle(.outline)
            .disabled(viewModel.items.isEmpty)
            Menu {
                FolderContextMenu(folderID: viewModel.folderID, main: main)
            } label: {
                Label(FolderCopy.actions, systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fxIconButtonStyle()
            .help(FolderCopy.actions)
        }
    }
}

/// The pill with the add actions on its right, or the selection's actions while several rows are
/// selected.
private struct FolderDetailControls: View {
    @Bindable var viewModel: FolderDetailViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.medium) {
                ConfigKindPill(viewModel: viewModel)
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                ConfigKindPill(viewModel: viewModel)
                actions
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if viewModel.selection.count > 1 {
            let rows = viewModel.selectedRows
            HStack(spacing: Theme.Spacing.mediumMinus) {
                Text(String(localized: "main.detail.selection.count", defaultValue: "\(rows.count) selected"))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
                CopyToMenu(
                    title: String(localized: "main.detail.selection.copyTo", defaultValue: "Copy To"),
                    rows: rows,
                    viewModel: viewModel,
                    showsChevron: true
                )
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fxButtonStyle(.outline)
                Button(String(localized: "main.table.delete", defaultValue: "Delete…")) {
                    viewModel.requestDeletion(of: rows)
                }
                .fxButtonStyle(.outline)
                Button {
                    viewModel.clearSelection()
                } label: {
                    Label(String(localized: "main.detail.selection.clear", defaultValue: "Deselect"), systemImage: "xmark")
                }
                .fxIconButtonStyle()
                .help(String(localized: "main.detail.selection.clear", defaultValue: "Deselect"))
            }
            .fixedSize()
        } else {
            ConfigAddActions(viewModel: viewModel)
        }
    }
}

/// Reveal, Copy Value, Edit…, Copy To, the linked copies and Delete… for one folder row.
private struct FolderRowActions: View {
    let row: ConfigRowModel
    let viewModel: FolderDetailViewModel

    var body: some View {
        if row.kind == .secret {
            Button(viewModel.isRevealed(row.id) ? MaskedValueCell.hideTitle : MaskedValueCell.revealTitle) {
                viewModel.toggleReveal(row.id)
            }
        }
        Button(String(localized: "main.table.copy", defaultValue: "Copy Value")) {
            viewModel.copy(row.id)
        }
        Divider()
        Button(String(localized: "main.table.edit", defaultValue: "Edit…")) {
            viewModel.edit(row)
        }
        CopyToMenu(title: String(localized: "main.table.copyTo", defaultValue: "Copy To"), rows: [row], viewModel: viewModel)
        if row.isLinked {
            Button(String(localized: "main.table.linked.show", defaultValue: "Show Linked Copies")) {
                viewModel.showLinkedCopies(of: row)
            }
            Button(String(localized: "main.table.linked.unlink", defaultValue: "Unlink")) {
                viewModel.unlink(row)
            }
        }
        Divider()
        Button(String(localized: "main.table.delete", defaultValue: "Delete…"), role: .destructive) {
            viewModel.requestDeletion(of: [row])
        }
    }
}

/// Copy To and Delete… for several folder rows.
private struct FolderSelectionMenu: View {
    let rows: [ConfigRowModel]
    let viewModel: FolderDetailViewModel

    var body: some View {
        CopyToMenu(
            title: String(localized: "main.table.several.copyTo", defaultValue: "Copy \(rows.count) Items To"),
            rows: rows,
            viewModel: viewModel
        )
        Divider()
        Button(String(localized: "main.table.several.delete", defaultValue: "Delete \(rows.count)…"), role: .destructive) {
            viewModel.requestDeletion(of: rows)
        }
    }
}
