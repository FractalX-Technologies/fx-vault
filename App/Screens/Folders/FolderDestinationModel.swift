import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// Where a received copy of a folder goes (v0.7.0, tasks/todo.md F7), from a `.fxvault` file:
/// **Save as Folder** (a new folder, by default named as the sender's,
/// or merged into one of this vault's folders where names it already has are kept or replaced),
/// or **Import Into a Repository** (a scope of a vault repository, through the usual import
/// preview). A folder of the same name is preselected for merging. Names and counts only.
@Observable
final class FolderDestinationModel {
    enum Choice: Hashable {
        case folder
        case repository
    }

    /// A new folder, or one of this vault's.
    enum FolderChoice: Hashable {
        case new
        case existing(FolderID)
    }

    let senderFolderName: String
    let secretCount: Int
    let variableCount: Int
    var choice: Choice = .folder
    private(set) var folders: [FolderModel] = []
    /// "Mobile › Development" for each folder in the picker.
    private(set) var folderTitles: [FolderID: String] = [:]
    var folderChoice: FolderChoice = .new
    var newFolderName: String
    /// Merging: replace the values of names the folder already has (off keeps them).
    var replacesExisting = false
    private(set) var repositories: [RepoModel] = []
    var repositoryID: RepoID? {
        didSet {
            if repositoryID != oldValue {
                loadScopes()
            }
        }
    }
    private(set) var scopes: [ConfigScopeSummaryModel] = []
    var scope: ConfigScope = .repository

    @ObservationIgnored private let dependencies: FeatureDependencies

    init(manifest: SharePackageModel, dependencies: FeatureDependencies) {
        self.dependencies = dependencies
        senderFolderName = manifest.folder?.name ?? ""
        secretCount = manifest.repository.secrets.count
        variableCount = manifest.repository.variables.count
        newFolderName = senderFolderName
        let all = (try? dependencies.folders.folders()) ?? []
        folders = all.treeOrdered
        folderTitles = Dictionary(uniqueKeysWithValues: all.map { ($0.id, PlaceCopy.path(all.path(of: $0.id))) })
        // A new folder lands at the top, so only a top-level folder of that name is the same one.
        if let same = folders.first(where: { $0.parentID == nil && $0.nameKey == FolderNameValidator.foldKey(senderFolderName) }) {
            folderChoice = .existing(same.id)
        }
        repositories = (try? dependencies.sharing.importTargets()) ?? []
    }

    // MARK: - Save as Folder

    /// Why the new folder's name cannot be used, or nil.
    var newFolderNameNote: ConfigEditorNoteModel? {
        guard choice == .folder, folderChoice == .new else { return nil }
        if let error = FolderNameValidator.violation(in: newFolderName) {
            return .error(error.localizedMessage)
        }
        if folders.contains(where: { $0.parentID == nil && $0.nameKey == FolderNameValidator.foldKey(newFolderName) }) {
            return .error(FolderCopy.nameTaken)
        }
        return nil
    }

    var saveTarget: FolderSaveTargetModel? {
        guard choice == .folder else { return nil }
        switch folderChoice {
        case .new:
            return newFolderNameNote == nil ? .newFolder(name: newFolderName) : nil
        case .existing(let id):
            return .existing(id)
        }
    }

    var conflicts: ItemCopyConflictPolicy {
        replacesExisting ? .replace : .keep
    }

    var isMerging: Bool {
        if case .existing = folderChoice { true } else { false }
    }

    // MARK: - Import Into a Repository

    /// Why `scope` of the chosen repository cannot take items, or nil.
    func readOnlyReason(for summary: ConfigScopeSummaryModel) -> RepoCapabilityModel.ReadOnlyReason? {
        repositories.first { $0.id == repositoryID }?.capability.readOnlyReason(for: summary.scope.level)
    }

    var importTarget: (repositoryID: RepoID, scope: ConfigScope)? {
        guard choice == .repository, let repositoryID,
              let summary = scopes.first(where: { $0.scope == scope }),
              readOnlyReason(for: summary) == nil
        else { return nil }
        return (repositoryID, scope)
    }

    var canContinue: Bool {
        switch choice {
        case .folder: saveTarget != nil
        case .repository: importTarget != nil
        }
    }

    private func loadScopes() {
        scope = .repository
        guard let repositoryID else {
            scopes = []
            return
        }
        scopes = ((try? dependencies.config.scopes(repositoryID: repositoryID)) ?? []).filter { !$0.isDeleted }
    }
}
