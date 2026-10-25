import SyncEngine
import VaultCore

/// Which pending GitHub changes a share hold keeps out of a Sync run (v0.9.0, tasks/todo.md P8).
/// Pure.
///
/// - A row held under a package the user did not include is left out with every change it
///   makes (an add, an update, a rename pair). A tombstone is never held: deleting a held row is
///   the user's own change.
/// - A new environment waits while every live item in it is held (its contents are the share
///   file's), and so do its branch patterns.
/// - An environment rename copies every live item into the new name, so it waits, with all its
///   copies, while any live item in it is held. Otherwise the held value would reach GitHub with
///   the rename, or be lost with the old environment.
struct HeldChangeFilter {
    /// Held rows whose package is not included, by item id.
    private let activeHolds: [ConfigItemID: SharePackageID]
    /// Environments whose create or rename waits, with the packages it waits for.
    let heldEnvironments: [EnvironmentID: Set<SharePackageID>]

    init(snapshot: RepoSnapshotModel, holds: [ConfigItemID: SharePackageID], included: Set<SharePackageID> = []) {
        var active: [ConfigItemID: SharePackageID] = [:]
        for item in snapshot.items where !item.isDeleted {
            if let packageID = holds[item.id], !included.contains(packageID) {
                active[item.id] = packageID
            }
        }
        activeHolds = active
        var environments: [EnvironmentID: Set<SharePackageID>] = [:]
        for environment in snapshot.environments where !environment.isDeleted {
            let live = snapshot.items(in: .environment(environment.id)).filter { !$0.isDeleted }
            let packages = live.compactMap { active[$0.id] }
            if !environment.isSynced {
                if !live.isEmpty, packages.count == live.count {
                    environments[environment.id] = Set(packages)
                }
            } else if environment.hasPendingRename, !packages.isEmpty {
                environments[environment.id] = Set(packages)
            }
        }
        heldEnvironments = environments
    }

    /// True when nothing in the snapshot is held.
    var isEmpty: Bool {
        activeHolds.isEmpty && heldEnvironments.isEmpty
    }

    /// The packages `change` waits for, or nil when it is not held.
    func packages(of change: ConfigChangeModel) -> Set<SharePackageID>? {
        var packages: Set<SharePackageID> = []
        switch change.operation {
        case .setItem(let set):
            if let packageID = activeHolds[set.itemID] { packages.insert(packageID) }
            if let environmentID = set.environmentID, let held = heldEnvironments[environmentID] {
                packages.formUnion(held)
            }
        case .deleteItem(let delete):
            if let packageID = activeHolds[delete.itemID] { packages.insert(packageID) }
        case .upsertEnvironment(let upsert):
            packages = heldEnvironments[upsert.environmentID] ?? []
        case .renameEnvironment(let rename):
            packages = heldEnvironments[rename.environmentID] ?? []
        case .reconcileBranchPatterns(let patterns):
            packages = heldEnvironments[patterns.environmentID] ?? []
        case .deleteEnvironment, .createRepository:
            break
        }
        return packages.isEmpty ? nil : packages
    }

    func isHeld(_ change: ConfigChangeModel) -> Bool {
        packages(of: change) != nil
    }

    /// `changeSet` without the held changes (for the §7.2 summary).
    func filter(_ changeSet: ChangeSetModel) -> ChangeSetModel {
        guard !isEmpty else { return changeSet }
        return ChangeSetModel(
            repository: changeSet.repository,
            changes: changeSet.changes.filter { !isHeld($0) },
            blocked: changeSet.blocked.filter { !isHeld($0.change) },
            notes: changeSet.notes
        )
    }

    /// `repository` without the held changes, executable or blocked; shared-scope gates stay
    /// only for the scopes a remaining change still writes to.
    func filter(_ repository: RepoPreflightModel) -> RepoPreflightModel {
        guard !isEmpty else { return repository }
        let executable = repository.executable.filter { !isHeld($0) }
        return RepoPreflightModel(
            snapshot: repository.snapshot,
            changeSet: filter(repository.changeSet),
            executable: executable,
            blocked: repository.blocked.filter { !isHeld($0.change) },
            repositoryVariableBytes: repository.repositoryVariableBytes
        )
    }

    /// The local scope a change writes to; nil for repository-wide changes.
    private static func scope(of change: ConfigChangeModel) -> ConfigScope? {
        switch change.operation {
        case .setItem(let set): set.environmentID.map(ConfigScope.environment) ?? .repository
        case .deleteItem(let delete): delete.environmentID.map(ConfigScope.environment) ?? .repository
        case .upsertEnvironment(let upsert): .environment(upsert.environmentID)
        case .renameEnvironment(let rename): .environment(rename.environmentID)
        case .reconcileBranchPatterns(let patterns): .environment(patterns.environmentID)
        case .deleteEnvironment(let delete): .environment(delete.environmentID)
        case .createRepository: nil
        }
    }
}

extension SyncPreflightModel {
    /// The preflight without the changes `filters` hold, with the write cost estimated again.
    func excludingHeld(_ filters: [RepoID: HeldChangeFilter]) -> SyncPreflightModel {
        guard filters.values.contains(where: { !$0.isEmpty }) else { return self }
        let repositories = repositories.map { repository in
            filters[repository.id].map { $0.filter(repository) } ?? repository
        }
        let cost = repositories.flatMap { repository in
            repository.executable.map { WriteCostEstimator.cost(of: $0, snapshot: repository.snapshot) }
        }.reduce(0, +)
        return SyncPreflightModel(
            runID: runID,
            repositories: repositories,
            writeBudgets: writeBudgets,
            estimatedWriteCost: cost
        )
    }
}
