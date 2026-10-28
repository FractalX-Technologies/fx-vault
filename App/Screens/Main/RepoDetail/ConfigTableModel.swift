import Foundation
import Observation
import VaultCore
import VaultData

/// What ``ConfigTableView``, ``LinkedChip``, ``LinkedCopiesPopover`` and ``CopyToMenu`` need from
/// the column that owns the table: a repository scope (``RepoDetailViewModel``) or, v0.7.0, a
/// folder (``FolderDetailViewModel``). Row menus stay with each owner, since a folder has no
/// sync state (no Revert, Push on Next Sync, Convert or Move).
protocol ConfigTableModel: AnyObject, Observable {
    var kind: ConfigKind { get set }
    /// The place's own rows of `kind`, by name (``rows`` is the open tab's).
    func rows(of kind: ConfigKind) -> [ConfigRowModel]
    /// What the table (and the notes) show of `kind`: the own rows, then a repository's
    /// inherited organization items (B7a).
    func tableRows(of kind: ConfigKind) -> [ConfigRowModel]
    /// The kinds the place holds, a section each in its notes (a Key Vault: secrets only).
    var notesKinds: [ConfigKind] { get }
    /// The rows the last check found changed at the source (the notes' ○ marks, 1.0 B9).
    var changedAtSourceIDs: Set<ConfigItemID> { get }
    var selection: Set<ConfigItemID> { get set }
    /// Items can be added, edited, pasted and deleted here.
    var canEdit: Bool { get }
    /// The Status column (repository scopes; a folder never syncs).
    var showsSyncStatus: Bool { get }
    /// The row whose linked copies popover is open.
    var linkedPopoverRowID: ConfigItemID? { get set }
    /// The other places of ``linkedPopoverRowID``.
    var linkedCopies: [LinkedCopyModel] { get }
    /// Copy To: scopes of this repository (empty for a folder).
    var scopeCopyTargets: [ItemCopyTargetModel] { get }
    /// Copy To › Folder: the folders (this one left out).
    var folderCopyTargets: [ItemCopyTargetModel] { get }
    /// Copy To › Destinations: the repository's destinations (v0.8.0; this one left out).
    var destinationCopyTargets: [ItemCopyTargetModel] { get }
    /// A copy waiting for "Replace or keep?".
    var pendingCopy: ItemCopyRequestModel? { get set }

    func rows(for ids: Set<ConfigItemID>) -> [ConfigRowModel]
    func count(of kind: ConfigKind) -> Int
    func add()
    func importEnvFile()
    func confirmCopy(replacing: Bool)
    func display(for row: ConfigRowModel) -> ConfigValueDisplayModel
    func isRevealed(_ id: ConfigItemID) -> Bool
    func toggleReveal(_ id: ConfigItemID)
    func copy(_ id: ConfigItemID)
    func edit(_ row: ConfigRowModel)
    func deleteSelection()
    func copySelection()
    /// Copy All (1.0 D6c4): the sheet that asks for Touch ID or the master password, then copies
    /// every live value of the place.
    func copyAll()
    func pasteMultiple()
    func copy(_ rows: [ConfigRowModel], to target: ItemCopyTargetModel)
    func copyToOtherRepository(_ rows: [ConfigRowModel])
    func showLinkedCopies(of row: ConfigRowModel)
    func openLinkedCopy(_ copy: LinkedCopyModel)
    func unlink(_ row: ConfigRowModel)
    /// The Held chip's tooltip (v0.9.0).
    func heldHelp(for row: ConfigRowModel) -> String
    /// Add File Secret… (1.0 F1): the sheet for this place, with the `url` of a dropped file.
    func addFileSecret(from url: URL?)
    /// Writes from outside the notes editor (a dropped file, ⌘V of copied items or `.env` text,
    /// Import .env…): an editable place, not while its notes are edited (1.0 N2).
    var acceptsOutsideEdits: Bool { get }
    /// The largest value the place stores (25,600 bytes in a Key Vault), for the drop overlay.
    var maxValueBytes: Int { get }
    /// A dropped file that can't be a file secret is kept as a file (a folder, v23).
    var keepsDroppedFiles: Bool { get }
    /// Keeps dropped files that aren't file secrets (``keepsDroppedFiles`` only).
    func keepDroppedFiles(_ urls: [URL])
    var alert: ErrorPresentationModel? { get set }
}

extension ConfigTableModel {
    /// The open tab's own rows.
    var rows: [ConfigRowModel] {
        rows(of: kind)
    }

    /// What the open tab's table shows.
    var tableRows: [ConfigRowModel] {
        tableRows(of: kind)
    }

    /// Only the place's own rows by default (a folder or a Key Vault inherits nothing).
    func tableRows(of kind: ConfigKind) -> [ConfigRowModel] {
        rows(of: kind)
    }

    var notesKinds: [ConfigKind] {
        ConfigKind.allCases
    }

    /// Nothing marked by default (a folder never syncs).
    var changedAtSourceIDs: Set<ConfigItemID> {
        []
    }

    /// No destinations by default (a folder belongs to no repository).
    var destinationCopyTargets: [ItemCopyTargetModel] {
        []
    }

    /// Without the sender's name (a folder never holds rows).
    func heldHelp(for row: ConfigRowModel) -> String {
        HeldShareCopy.chipHelp(sender: nil)
    }

    var acceptsOutsideEdits: Bool {
        canEdit
    }

    /// Only a folder keeps files.
    var keepsDroppedFiles: Bool {
        false
    }

    func keepDroppedFiles(_ urls: [URL]) {}

    /// The ⌘V validator of the place's column: the providers while it takes outside edits, nil
    /// (Paste disabled) otherwise.
    func validatePaste(_ providers: [NSItemProvider]) -> [NSItemProvider]? {
        acceptsOutsideEdits ? providers : nil
    }

    /// Files dropped on the place. A folder keeps several at once as files (v23); elsewhere the
    /// first one counts, as ``dropFile(_:)`` says.
    func dropFiles(_ urls: [URL]) {
        guard acceptsOutsideEdits else { return }
        if urls.count > 1, keepsDroppedFiles {
            keepDroppedFiles(urls.filter(\.isFileURL))
        } else if let url = urls.first {
            dropFile(url)
        }
    }

    /// A file dropped on the place (1.0 F1; board Place-FileDrop): a .p8, .pem or .json file
    /// opens Add file secret with it. A folder keeps any other file, and a key file too large
    /// for a value (v23); elsewhere it is refused: a drop is quick to do by mistake, and Choose…
    /// in the sheet takes every file.
    func dropFile(_ url: URL) {
        guard acceptsOutsideEdits else { return }
        let isSecretFile = FileSecretRules.isDroppable(fileName: url.lastPathComponent)
            && !(keepsDroppedFiles && Self.byteCount(of: url).map { $0 > maxValueBytes } == true)
        if url.isFileURL, !isSecretFile, keepsDroppedFiles {
            keepDroppedFiles([url])
            return
        }
        guard url.isFileURL, isSecretFile else {
            alert = ErrorPresentationModel(title: FileSecretCopy.notDroppableTitle, message: FileSecretCopy.notDroppableMessage)
            return
        }
        addFileSecret(from: url)
    }

    private static func byteCount(of url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    /// New Secret or New Variable from a place's ⋯ More (1.0 D6c3): that kind's tab first, so
    /// the new row shows when the editor closes.
    func add(_ kind: ConfigKind) {
        self.kind = kind
        add()
    }

    /// The selected rows of the visible kind, in table order.
    var selectedRows: [ConfigRowModel] {
        rows(for: selection)
    }

    /// The selection bar needs two of the place's own rows: selected inherited rows (B7a) have
    /// nothing to count, copy or delete, and a selected row that is gone counts for nothing.
    var showsSelectionActions: Bool {
        selectedRows.count > 1
    }

    /// ⌘C needs a selected row of the place's own: an inherited one (B7a) is not copied.
    var canCopySelection: Bool {
        !rows(for: selection).isEmpty
    }

    /// What a place's Copy To copies (1.0 D6c3): the selected rows, or the open tab's rows when
    /// none is selected; never a deleted one.
    var placeCopyRows: [ConfigRowModel] {
        let selected = rows(for: selection)
        return (selected.isEmpty ? rows : selected).filter { !$0.isDeleted }
    }

    /// Delete Selected… in ⋯ More: a selected row that is not already a pending deletion, in a
    /// place whose items can change. A selection of tombstones alone has nothing to delete.
    var canDeleteSelection: Bool {
        canEdit && rows(for: selection).contains { !$0.isDeleted }
    }

    /// Copy All needs a live item of either kind (both tabs, whatever is selected).
    var canCopyAll: Bool {
        ConfigKind.allCases.contains { count(of: $0) > 0 }
    }
}
