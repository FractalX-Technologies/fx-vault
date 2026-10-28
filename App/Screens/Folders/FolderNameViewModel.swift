import Foundation
import Observation
import VaultCore
import VaultData

/// New Folder…, New Subfolder… and Rename… (v0.7.0): one name, checked live with
/// `FolderNameValidator` and against its siblings (case-insensitive). A new folder is selected
/// in the sidebar.
@Observable
final class FolderNameViewModel {
    let context: FolderNameContext
    var name = ""
    private(set) var isSaving = false
    var alert: ErrorPresentationModel?
    private(set) var otherKeys: Set<String> = []

    @ObservationIgnored private let dependencies: FeatureDependencies

    init(context: FolderNameContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
        let folders = (try? dependencies.folders.folders()) ?? []
        switch context.mode {
        case .rename(let id):
            let folder = folders.first { $0.id == id }
            name = folder?.name ?? ""
            otherKeys = Set(folders.filter { $0.id != id && $0.parentID == folder?.parentID }.map(\.nameKey))
        case .create(_, let parent):
            parentName = parent.flatMap { parent in folders.first { $0.id == parent }?.name }
            otherKeys = Set(folders.filter { $0.parentID == parent }.map(\.nameKey))
        }
    }

    /// The folder a new subfolder goes in, for the title.
    private(set) var parentName: String?

    var isRenaming: Bool {
        if case .rename = context.mode { true } else { false }
    }

    var title: String {
        if isRenaming { return FolderCopy.renameTitle }
        return parentName.map(FolderCopy.newSubfolderTitle) ?? FolderCopy.newTitle
    }

    var primaryTitle: String {
        isRenaming ? FolderCopy.renameSubmit : FolderCopy.create
    }

    /// The live problem with the typed name (nothing while it is empty).
    var nameNote: ConfigEditorNoteModel? {
        guard !name.isEmpty else { return nil }
        if let error = FolderNameValidator.violation(in: name) {
            return .error(error.localizedMessage)
        }
        if otherKeys.contains(FolderNameValidator.foldKey(name)) {
            return .error(FolderCopy.nameTaken)
        }
        return nil
    }

    var canSave: Bool {
        !name.isEmpty && nameNote == nil && !isSaving
    }

    /// Creates or renames; returns true when the sheet can close.
    func save() -> Bool {
        guard canSave else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            switch context.mode {
            case .create(let itemIDs, let parent):
                let id = try dependencies.folders.createFolder(named: name, in: parent)
                if !itemIDs.isEmpty {
                    try dependencies.folders.copyItems(itemIDs, to: id, conflicts: .keep)
                }
                dependencies.actions.openFolder(id)
            case .rename(let id):
                try dependencies.folders.renameFolder(id, to: name)
            }
            return true
        } catch {
            alert = error.presentation
            return false
        }
    }
}
