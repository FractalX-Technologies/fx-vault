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
    var rows: [ConfigRowModel] { get }
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
    func pasteMultiple()
    func copy(_ rows: [ConfigRowModel], to target: ItemCopyTargetModel)
    func copyToOtherRepository(_ rows: [ConfigRowModel])
    func showLinkedCopies(of row: ConfigRowModel)
    func openLinkedCopy(_ copy: LinkedCopyModel)
    func unlink(_ row: ConfigRowModel)
    /// The Held chip's tooltip (v0.9.0).
    func heldHelp(for row: ConfigRowModel) -> String
}

extension ConfigTableModel {
    /// No destinations by default (a folder belongs to no repository).
    var destinationCopyTargets: [ItemCopyTargetModel] {
        []
    }

    /// Without the sender's name (a folder never holds rows).
    func heldHelp(for row: ConfigRowModel) -> String {
        HeldShareCopy.chipHelp(sender: nil)
    }

    /// New Secret or New Variable from a place's ⋯ More (1.0 D6c3): that kind's tab first, so
    /// the new row shows when the editor closes.
    func add(_ kind: ConfigKind) {
        self.kind = kind
        add()
    }

    /// What a place's Copy To copies (1.0 D6c3): the selected rows, or the open tab's rows when
    /// none is selected; never a deleted one.
    var placeCopyRows: [ConfigRowModel] {
        let selected = rows(for: selection)
        return (selected.isEmpty ? rows : selected).filter { !$0.isDeleted }
    }
}
