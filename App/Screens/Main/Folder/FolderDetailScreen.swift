import SwiftUI
import VaultCore
import VaultData

/// Column 3 for a folder (v0.7.0; board Folder-View): the header (the name, "Folder · never sent
/// anywhere by itself · counts", Copy To, Share Securely…, Notes | Table, ⋯ More), then the notes,
/// or the Secrets | Variables pill with the selection's actions and the table without Status.
struct FolderDetailScreen: View {
    @Bindable var viewModel: FolderDetailViewModel
    let main: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumPlus) {
            FolderDetailHeader(viewModel: viewModel, main: main)
            switch main.placeViewMode {
            case .notes:
                PlaceNotesContent(model: viewModel)
            case .table:
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
            }
            if let notice = viewModel.notice {
                Text(notice)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        }
        .fxPlaceColumn()
        .onPasteCommand(of: [.plainText], validator: viewModel.validatePaste) { providers in
            Task { await viewModel.handlePaste(providers) }
        }
        .fileSecretDropTarget(viewModel)
        .notesRevealSheet(viewModel.notesReveal)
        .errorAlert($viewModel.alert)
        .deleteItemsSheet(viewModel.deletionSheet) {
            viewModel.pendingDeletion = nil
        } confirm: {
            viewModel.confirmDeletion()
        }
        .modifier(ItemCopyConflictDialog(viewModel: viewModel))
    }
}

/// The folder's name in sans (the user named it), its subline, Copy To and Share Securely… as on
/// board Folder-View, and ⋯ More: New Secret, New Variable, Paste Multiple…, Import .env…, Copy
/// All, Delete Selected…, then the folder's own menu (Rename…, Share Securely…, Export .env…,
/// Delete Folder…).
private struct FolderDetailHeader: View {
    let viewModel: FolderDetailViewModel
    let main: MainViewModel

    var body: some View {
        if let edit = viewModel.notesEdit {
            NotesEditHeader(title: viewModel.folder?.name ?? "", titleStyle: .sans, session: edit)
        } else {
            header
        }
    }

    private var header: some View {
        PlaceHeader(title: viewModel.folder?.name ?? "", titleStyle: .sans, subline: viewModel.subline) {
            CopyToMenu(title: PlaceCopy.copyTo, rows: viewModel.placeCopyRows, viewModel: viewModel, showsChevron: true)
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fxButtonStyle(.outline, size: .compact)
            Button(PlaceCopy.shareSecurely) {
                viewModel.shareAsFile()
            }
            .fxButtonStyle(.outline, size: .compact)
            .disabled(viewModel.items.isEmpty)
            PlaceViewModePicker(main: main)
        } moreItems: {
            NotesEditMenuItem(model: viewModel, main: main)
            Divider()
            PlaceItemMoreItems(viewModel: viewModel) {
                CopyAllMenuItem(isEnabled: viewModel.canCopyAll) {
                    viewModel.copyAll()
                }
            }
            Divider()
            FolderContextMenu(folderID: viewModel.folderID, main: main)
        }
    }
}

/// The pill, with the selection's actions on its right while several rows are selected.
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
        if viewModel.showsSelectionActions {
            let rows = viewModel.selectedRows
            HStack(spacing: Theme.Spacing.mediumMinus) {
                Text(String(localized: "main.detail.selection.count", defaultValue: "\(rows.count) selected"))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
                CopyToMenu(
                    title: PlaceCopy.copyTo,
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
        CopyToMenu(title: PlaceCopy.copyTo, rows: [row], viewModel: viewModel)
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
