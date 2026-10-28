import Foundation
import SharingKit
import VaultCore
import VaultData

/// The tree of a project share (v0.9.0, tasks/todo.md P1–P2): one root per chosen repository
/// (repository level, environments, destinations, items) and one row per folder. Names only.
///
/// Like ``ShareScopeTreeModel``, the state is the set of checked **leaves** (every secret and
/// variable, plus each environment or destination without items and each folder), and a parent
/// is checked when every leaf under it is. ``selection(stages:expiry:)`` encodes the checks for
/// `SharingRepository.exportBundle`: a checked repository-level group, environment or destination
/// travels whole (an environment with its branch policy); a mixed one travels as its checked
/// items only.
struct ProjectShareTreeModel: Equatable, ShareCheckTree {
    /// One repository's part of the tree.
    struct RepositoryPart: Equatable {
        let repositoryID: RepoID
        let fullName: String
        /// Environments and destinations in tree order.
        let environmentIDs: [EnvironmentID]
        let destinationIDs: [DestinationID]
        let hasRepositoryLevel: Bool
    }

    private(set) var roots: [ShareScopeNodeModel]
    private(set) var parts: [RepositoryPart]
    private(set) var folderIDs: [FolderID]
    private(set) var checkedLeaves: Set<ShareScopeNodeID> = []
    private var leaves: [ShareScopeNodeID: Set<ShareScopeNodeID>] = [:]

    /// - Parameters:
    ///   - repositories: each repository's node (``ShareScopeTreeModel/repositoryNode(repository:scopes:items:destinations:)``)
    ///     and its part, in the order the sheet lists them.
    ///   - folders: the vault's folders that can be added (each one a leaf row, a subfolder
    ///     titled "Mobile › Development").
    ///   - allFolders: every folder, for those titles.
    init(repositories: [(node: ShareScopeNodeModel, part: RepositoryPart)], folders: [FolderModel], allFolders: [FolderModel]) {
        parts = repositories.map(\.part)
        folderIDs = folders.map(\.id)
        let folderNodes = folders.map { folder in
            ShareScopeNodeModel(
                id: .folder(folder.id),
                title: PlaceCopy.path(allFolders.path(of: folder.id)),
                kind: .folder,
                children: nil,
                ownCounts: ShareItemCountModel(secrets: folder.secretCount, variables: folder.variableCount)
            )
        }
        roots = repositories.map(\.node) + folderNodes
        var leaves: [ShareScopeNodeID: Set<ShareScopeNodeID>] = [:]
        @discardableResult
        func collect(_ node: ShareScopeNodeModel) -> Set<ShareScopeNodeID> {
            let children = node.children ?? []
            let under = children.isEmpty
                ? (ShareScopeTreeModel.isLeafCandidate(node) ? [node.id] : [])
                : children.reduce(into: Set<ShareScopeNodeID>()) { $0.formUnion(collect($1)) }
            leaves[node.id] = under
            return under
        }
        roots.forEach { collect($0) }
        self.leaves = leaves
    }

    // MARK: - State

    func state(of node: ShareScopeNodeModel) -> ShareCheckState {
        state(of: node.id)
    }

    func state(of id: ShareScopeNodeID) -> ShareCheckState {
        let under = leaves[id] ?? []
        guard !under.isEmpty else { return .unchecked }
        let checked = under.intersection(checkedLeaves).count
        if checked == 0 { return .unchecked }
        return checked == under.count ? .checked : .mixed
    }

    /// Checks (`true`) or unchecks everything under `node`.
    mutating func setChecked(_ checked: Bool, for node: ShareScopeNodeModel) {
        let under = leaves[node.id] ?? []
        if checked {
            checkedLeaves.formUnion(under)
        } else {
            checkedLeaves.subtract(under)
        }
    }

    /// Checks or unchecks the repository-level group of every repository.
    mutating func setRepositoryLevel(_ checked: Bool) {
        for part in parts where part.hasRepositoryLevel {
            let under = leaves[.repositoryLevel(part.repositoryID)] ?? []
            if checked {
                checkedLeaves.formUnion(under)
            } else {
                checkedLeaves.subtract(under)
            }
        }
    }

    /// True when nothing is checked.
    var isEmpty: Bool {
        checkedLeaves.isEmpty
    }

    // MARK: - Selection

    /// Replaces the repositories' checks with `selection` (a stage expansion); folder checks are
    /// kept, and the selection's folders are added.
    mutating func apply(_ selection: ShareBundleSelectionModel) {
        let folderLeaves = checkedLeaves.filter { if case .folder = $0 { true } else { false } }
        var checked = Set(folderLeaves)
        checked.formUnion(selection.folderIDs.map { ShareScopeNodeID.folder($0) }.filter { leaves[$0] != nil })
        for part in selection.repositories {
            if part.includesRepositoryLevel {
                checked.formUnion(leaves[.repositoryLevel(part.repositoryID)] ?? [])
            }
            for id in part.environmentIDs {
                checked.formUnion(leaves[.environment(id)] ?? [])
            }
            for id in part.destinationIDs {
                checked.formUnion(leaves[.destination(id)] ?? [])
            }
            for id in part.itemIDs.union(part.destinationItemIDs) {
                checked.formUnion(leaves[.item(id)] ?? [])
            }
        }
        checkedLeaves = checked
    }

    /// What the checked rows share, per repository in tree order (repositories with nothing
    /// checked are left out).
    func selection(stages: [String], expiry: ShareExpiryChoice) -> ShareBundleSelectionModel {
        var repositories: [ShareBundleRepositorySelectionModel] = []
        for part in parts {
            var selection = ShareBundleRepositorySelectionModel(repositoryID: part.repositoryID, includesRepositoryLevel: false)
            if part.hasRepositoryLevel {
                let group = ShareScopeNodeID.repositoryLevel(part.repositoryID)
                switch state(of: group) {
                case .checked: selection.includesRepositoryLevel = true
                case .mixed: selection.itemIDs.formUnion(checkedItems(under: group))
                case .unchecked: break
                }
            }
            for id in part.environmentIDs {
                switch state(of: .environment(id)) {
                case .checked: selection.environmentIDs.insert(id)
                case .mixed: selection.itemIDs.formUnion(checkedItems(under: .environment(id)))
                case .unchecked: break
                }
            }
            for id in part.destinationIDs {
                switch state(of: .destination(id)) {
                case .checked: selection.destinationIDs.insert(id)
                case .mixed: selection.destinationItemIDs.formUnion(checkedItems(under: .destination(id)))
                case .unchecked: break
                }
            }
            if !selection.isEmpty {
                repositories.append(selection)
            }
        }
        let folders = folderIDs.filter { checkedLeaves.contains(.folder($0)) }
        return ShareBundleSelectionModel(repositories: repositories, folderIDs: folders, stages: stages, expiry: expiry)
    }

    private func checkedItems(under id: ShareScopeNodeID) -> Set<ConfigItemID> {
        Set((leaves[id] ?? []).intersection(checkedLeaves).compactMap { leaf -> ConfigItemID? in
            if case .item(let itemID) = leaf { return itemID }
            return nil
        })
    }
}

/// Reads what the project share tree shows (names only): repositories with their scopes and
/// items, their destinations with items, and the folders.
struct ProjectShareTreeLoader {
    let config: ConfigRepository
    let destinations: DestinationRepository
    let folders: FolderRepository

    /// Every repository in the vault, by full name.
    func repositories() async throws -> [RepoModel] {
        let all = try await Self.first(of: config.observeRepositories()) ?? []
        return all.sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
    }

    /// The tree of `repositoryIDs` (in that order) plus every folder.
    func tree(repositories chosen: [RepoModel]) async throws -> ProjectShareTreeModel {
        var entries: [(node: ShareScopeNodeModel, part: ProjectShareTreeModel.RepositoryPart)] = []
        for repository in chosen {
            let scopes = try config.scopes(repositoryID: repository.id)
            var items: [ConfigScope: [ConfigItemModel]] = [:]
            for summary in scopes where summary.environment?.isDeleted != true {
                items[summary.scope] = try await Self.first(
                    of: config.observeItems(repositoryID: repository.id, scope: summary.scope)
                ) ?? []
            }
            let runtime = try destinations.destinations(repositoryID: repository.id).map { destination in
                (destination: destination, items: try destinations.items(destinationID: destination.id))
            }
            let node = ShareScopeTreeModel.repositoryNode(repository: repository, scopes: scopes, items: items, destinations: runtime)
            let part = ProjectShareTreeModel.RepositoryPart(
                repositoryID: repository.id,
                fullName: repository.fullName,
                environmentIDs: scopes.compactMap { summary in
                    guard let environment = summary.environment, !environment.isDeleted else { return nil }
                    return environment.id
                },
                destinationIDs: runtime.map(\.destination.id),
                hasRepositoryLevel: !(items[.repository] ?? []).filter { !$0.isDeleted }.isEmpty
            )
            entries.append((node, part))
        }
        let allFolders = try folders.folders()
        let shareable = allFolders.treeOrdered.filter { $0.itemCount > 0 }
        return ProjectShareTreeModel(repositories: entries, folders: shareable, allFolders: allFolders)
    }

    /// The current value of an observation stream (database observations deliver it at once).
    private static func first<Value>(of stream: AsyncThrowingStream<Value, any Error>) async throws -> Value? {
        for try await value in stream {
            return value
        }
        return nil
    }
}
