import Foundation
import Observation
import VaultCore
import VaultData

/// New Folder… and Rename… (v0.7.0): one name, checked live with `FolderNameValidator` and
/// against the other folders (case-insensitive). A new folder is selected in the sidebar.
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
        if case .rename(let id) = context.mode {
            name = folders.first { $0.id == id }?.name ?? ""
            otherKeys = Set(folders.filter { $0.id != id }.map(\.nameKey))
        } else {
            otherKeys = Set(folders.map(\.nameKey))
        }
    }

    var isRenaming: Bool {
        if case .rename = context.mode { true } else { false }
    }

    var title: String {
        isRenaming ? FolderCopy.renameTitle : FolderCopy.newTitle
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
            case .create(let itemIDs):
                let id = try dependencies.folders.createFolder(named: name)
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
