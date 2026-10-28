import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VaultCore
import VaultData

/// Column 3 for a folder (v0.7.0; board Folder-View): the header (the name, "Folder · never sent
/// anywhere by itself · counts", Copy To, Share Securely…, Notes | Table, ⋯ More), then the notes,
/// or the Secrets | Variables pill with the selection's actions and the table without Status,
/// then the folder's files (v23).
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
            if !viewModel.files.isEmpty {
                FolderFilesSection(viewModel: viewModel)
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
        .modifier(FolderFileDialogs(viewModel: viewModel))
    }
}

/// The folder's name in sans (the user named it), its subline, Copy To and Share Securely… as on
/// board Folder-View, and ⋯ More: New Secret, New Variable, Paste Multiple…, Import .env…, Copy
/// All, Delete Selected…, Add File…, then the folder's own menu (Rename…, Share Securely…, Export .env…,
/// Delete Folder…).
private struct FolderDetailHeader: View {
    let viewModel: FolderDetailViewModel
    let main: MainViewModel

    var body: some View {
        if let edit = viewModel.notesEdit {
            NotesEditHeader(title: viewModel.title, titleStyle: .sans, session: edit)
        } else {
            header
        }
    }

    private var header: some View {
        PlaceHeader(title: viewModel.title, titleStyle: .sans, subline: viewModel.subline) {
            RevealAllButton(model: viewModel, main: main)
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
            Button(FolderFileCopy.addFile) {
                viewModel.addFiles(FolderFilePanels.chooseFiles())
            }
            .disabled(!viewModel.canEdit)
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
        Button(PlaceCopy.copyValue) {
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

/// The folder's files (v23): "Files · N" with Add File…, then one row per file, scrolling after
/// ``Theme/Layout/folderFilesVisibleRows``.
private struct FolderFilesSection: View {
    let viewModel: FolderDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Text(FolderFileCopy.sectionTitle(count: viewModel.files.count))
                    .fxTextStyle(.sectionLabel)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if viewModel.canEdit {
                    Button(FolderFileCopy.addFile) {
                        viewModel.addFiles(FolderFilePanels.chooseFiles())
                    }
                    .fxButtonStyle(.outline, size: .compact)
                    .accessibilityIdentifier(AccessibilityID.FolderFiles.add)
                }
            }
            if viewModel.files.count > Theme.Layout.folderFilesVisibleRows {
                ScrollView {
                    rows
                }
                .frame(height: CGFloat(Theme.Layout.folderFilesVisibleRows) * Theme.Layout.tableRowHeight)
            } else {
                rows
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.FolderFiles.section)
    }

    private var rows: some View {
        LazyVStack(spacing: 0) {
            ForEach(viewModel.files) { file in
                FolderFileRow(file: file, viewModel: viewModel)
            }
        }
    }
}

/// A file's Finder icon, name and size, Save As… on the row, and Save As…, Rename… and Delete…
/// in its context menu.
private struct FolderFileRow: View {
    let file: FolderFileModel
    let viewModel: FolderDetailViewModel

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: Theme.Layout.folderFileIconSize, height: Theme.Layout.folderFileIconSize)
                .accessibilityHidden(true)
            Text(file.name)
                .fxTextStyle(.body)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Spacing.small)
            Text(FolderFileCopy.size(file.byteCount))
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.mutedText)
            Button(FolderFileCopy.saveAs, action: save)
                .fxButtonStyle(.outline, size: .compact)
                .accessibilityIdentifier(AccessibilityID.FolderFiles.save(file.name))
        }
        .frame(height: Theme.Layout.tableRowHeight)
        .contentShape(Rectangle())
        .contextMenu {
            Button(FolderFileCopy.saveAs, action: save)
            if viewModel.canEdit {
                Button(FolderFileCopy.rename) {
                    viewModel.beginRename(file)
                }
                Divider()
                Button(FolderFileCopy.delete, role: .destructive) {
                    viewModel.requestFileDeletion(file)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.FolderFiles.row(file.name))
    }

    private var icon: NSImage {
        let ext = (file.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }

    private func save() {
        guard let destination = FolderFilePanels.chooseDestination(fileName: file.name) else { return }
        viewModel.save(file, to: destination)
    }
}

/// Rename… (an alert with the name), "Delete?", and Save As…'s "Confirm it's you".
private struct FolderFileDialogs: ViewModifier {
    @Bindable var viewModel: FolderDetailViewModel

    func body(content: Content) -> some View {
        @Bindable var fileSave = viewModel.fileSave
        let saveRequest = Binding(
            get: { fileSave.pending },
            set: { if $0 == nil { fileSave.cancel() } }
        )
        content
            .alert(FolderFileCopy.renameTitle, isPresented: isRenaming, presenting: viewModel.renamingFile) { _ in
                TextField(FolderFileCopy.renameTitle, text: $viewModel.fileNameDraft)
                    .accessibilityIdentifier(AccessibilityID.FolderFiles.renameField)
                Button(FolderFileCopy.renameSubmit) {
                    viewModel.commitRename()
                }
                .keyboardShortcut(.defaultAction)
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
            }
            .confirmationDialog(
                FolderFileCopy.deleteTitle(viewModel.pendingFileDeletion?.name ?? ""),
                isPresented: isDeleting,
                titleVisibility: .visible,
                presenting: viewModel.pendingFileDeletion
            ) { _ in
                Button(FolderFileCopy.deleteConfirm, role: .destructive) {
                    viewModel.confirmFileDeletion()
                }
            } message: { _ in
                Text(FolderFileCopy.deleteMessage)
            }
            .sheet(item: saveRequest) { request in
                FolderFileSaveDialog(request: request, fileSave: fileSave)
            }
            .errorAlert($fileSave.alert)
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { viewModel.renamingFile != nil },
            set: { if !$0 { viewModel.renamingFile = nil } }
        )
    }

    private var isDeleting: Binding<Bool> {
        Binding(
            get: { viewModel.pendingFileDeletion != nil },
            set: { if !$0 { viewModel.pendingFileDeletion = nil } }
        )
    }
}

private struct FolderFileSaveDialog: View {
    let request: FolderFileSaveModel.Request
    let fileSave: FolderFileSaveModel

    var body: some View {
        DialogSheet(title: FolderFileCopy.saveTitle(request.file.name)) {
            if let reauth = fileSave.reauth {
                ReauthView(
                    model: reauth,
                    message: FolderFileCopy.saveMessage,
                    onTouchID: { await fileSave.authenticateWithTouchID() },
                    onPassword: { await fileSave.authenticateWithPassword() }
                )
            }
        } actions: {
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                fileSave.cancel()
            }
            .fxButtonStyle(.outline, size: .dialog)
            .keyboardShortcut(.cancelAction)
        }
        .frame(width: Theme.Layout.sheetWidth)
        .task { await fileSave.start() }
    }
}
