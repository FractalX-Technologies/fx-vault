import Foundation
import GitHubKit
import VaultCore

/// The data of the deletion confirmation (tasks/todo.md §7.5): for every environment being
/// deleted, its contents are fetched **live** (B4, B5, B7, B9) and merged with the local names;
/// names GitHub has but the vault does not are "not in your vault: will be lost". A failed fetch
/// yields ``EnvironmentContentsState/unknown(_:)`` (the view then requires an extra
/// acknowledgement). Values are never kept: listed variable values are wiped immediately.
public struct DeletionPreviewLoader: Sendable {
    private let schedulers: SyncSchedulerRegistry

    public init(schedulers: SyncSchedulerRegistry) {
        self.schedulers = schedulers
    }

    /// The preview of every repository that deletes something.
    public func load(_ preflight: SyncPreflightModel) async -> [RepoDeletionPreviewModel] {
        var previews: [RepoDeletionPreviewModel] = []
        for repository in preflight.repositories where !repository.deletions.isEmpty {
            previews.append(await load(repository))
        }
        return previews
    }

    /// The preview of one repository.
    public func load(_ repository: RepoPreflightModel) async -> RepoDeletionPreviewModel {
        let snapshot = repository.snapshot
        let itemDeletions = repository.deletions.filter { $0.kind != .deleteEnvironment }
        var environments: [EnvironmentDeletionPreviewModel] = []
        for change in repository.deletions {
            guard case .deleteEnvironment(let delete) = change.operation else { continue }
            let local = Self.localItems(of: delete, snapshot: snapshot)
            let contents = await fetchContents(delete, repository: snapshot.repository, local: local)
            environments.append(EnvironmentDeletionPreviewModel(
                change: change,
                environmentID: delete.environmentID,
                name: delete.name,
                contents: contents
            ))
        }
        return RepoDeletionPreviewModel(
            repositoryID: snapshot.repository.id,
            fullName: snapshot.repository.fullName,
            itemDeletions: itemDeletions,
            environments: environments
        )
    }

    private func fetchContents(
        _ delete: EnvironmentDeleteChangeModel,
        repository: RepoModel,
        local: [DeletionPreviewItemModel]
    ) async -> EnvironmentContentsState {
        guard let scheduler = schedulers.scheduler(for: repository.accountLogin) else {
            return .unknown(.notAuthenticated)
        }
        do {
            let ref = try GHRepoRef(owner: repository.ownerLogin, name: repository.name)
            guard let environment = try await scheduler.environment(ref, named: delete.name) else {
                return .alreadyDeleted
            }
            var patterns: [String] = []
            if environment.branchPolicyKind == .custom {
                patterns = try await scheduler.listBranchPolicies(ref, environment: environment.name).map(\.name)
            }
            let secrets = try await scheduler.listSecrets(ref, environment: environment.name)
            let variables = try await scheduler.listVariables(ref, environment: environment.name)
            let variableNames = variables.map(\.name)
            variables.forEach { $0.wipe() }
            return .loaded(EnvironmentContentsModel(
                policy: environment.branchPolicyKind,
                patterns: patterns.sorted(),
                foreignRulesJSON: environment.foreignRulesJSON,
                items: Self.merge(
                    local: local,
                    remote: secrets.map { ($0.name, ConfigKind.secret) } + variableNames.map { ($0, ConfigKind.variable) }
                )
            ))
        } catch {
            return .unknown(error)
        }
    }

    /// The environment's local names (synced names of its rows, tombstones included).
    private static func localItems(of delete: EnvironmentDeleteChangeModel, snapshot: RepoSnapshotModel) -> [DeletionPreviewItemModel] {
        let rows = snapshot.items(in: .environment(delete.environmentID))
        let names = rows.map { DeletionPreviewItemModel(name: $0.syncedName ?? $0.name, kind: $0.kind, isInVault: true, isOnGitHub: false) }
        let implied = delete.impliedItems.map { DeletionPreviewItemModel(name: $0.name, kind: $0.kind, isInVault: true, isOnGitHub: false) }
        return names + implied
    }

    private static func merge(local: [DeletionPreviewItemModel], remote: [(String, ConfigKind)]) -> [DeletionPreviewItemModel] {
        struct Key: Hashable {
            let nameKey: String
            let kind: ConfigKind
        }
        var merged: [Key: DeletionPreviewItemModel] = [:]
        for item in local {
            merged[Key(nameKey: GitHubNameValidator.foldKey(item.name), kind: item.kind)] = item
        }
        for (name, kind) in remote {
            let key = Key(nameKey: GitHubNameValidator.foldKey(name), kind: kind)
            if var existing = merged[key] {
                existing.isOnGitHub = true
                merged[key] = existing
            } else {
                merged[key] = DeletionPreviewItemModel(name: name, kind: kind, isInVault: false, isOnGitHub: true)
            }
        }
        return merged.values.sorted { lhs, rhs in
            lhs.kind != rhs.kind ? lhs.kind == .variable : GitHubNameValidator.foldKey(lhs.name) < GitHubNameValidator.foldKey(rhs.name)
        }
    }
}

/// One repository's deletions (§7.5).
public struct RepoDeletionPreviewModel: Sendable, Hashable, Identifiable {
    public var repositoryID: RepoID
    public var fullName: String
    /// Item deletes (tombstones, the old half of item renames, items of recreated environments).
    public var itemDeletions: [ConfigChangeModel]
    public var environments: [EnvironmentDeletionPreviewModel]

    public init(
        repositoryID: RepoID,
        fullName: String,
        itemDeletions: [ConfigChangeModel],
        environments: [EnvironmentDeletionPreviewModel]
    ) {
        self.repositoryID = repositoryID
        self.fullName = fullName
        self.itemDeletions = itemDeletions
        self.environments = environments
    }

    public var id: RepoID {
        repositoryID
    }

    /// "Delete N items on GitHub".
    public var deletionCount: Int {
        itemDeletions.count + environments.count
    }

    /// True when a contents fetch failed (the view requires the extra acknowledgement).
    public var hasUnknownContents: Bool {
        environments.contains { if case .unknown = $0.contents { true } else { false } }
    }
}

/// One environment being deleted.
public struct EnvironmentDeletionPreviewModel: Sendable, Hashable, Identifiable {
    public var change: ConfigChangeModel
    public var environmentID: EnvironmentID
    /// The remote name (`synced_name`). The view warns that workflows referencing it recreate it
    /// empty.
    public var name: String
    public var contents: EnvironmentContentsState

    public init(change: ConfigChangeModel, environmentID: EnvironmentID, name: String, contents: EnvironmentContentsState) {
        self.change = change
        self.environmentID = environmentID
        self.name = name
        self.contents = contents
    }

    public var id: String {
        change.id
    }
}

/// What the live fetch found.
public enum EnvironmentContentsState: Sendable, Hashable {
    case loaded(EnvironmentContentsModel)
    /// GitHub no longer has the environment (the delete will just confirm it).
    case alreadyDeleted
    /// "Contents unknown": the fetch failed.
    case unknown(GHError)
}

/// An environment's live contents merged with the vault's names.
public struct EnvironmentContentsModel: Sendable, Hashable {
    public var policy: BranchPolicyKind
    public var patterns: [String]
    /// Reviewers, wait timers and app rules from the fresh GET.
    public var foreignRulesJSON: String?
    /// Variables first, then secrets, by name.
    public var items: [DeletionPreviewItemModel]

    public init(policy: BranchPolicyKind, patterns: [String], foreignRulesJSON: String?, items: [DeletionPreviewItemModel]) {
        self.policy = policy
        self.patterns = patterns
        self.foreignRulesJSON = foreignRulesJSON
        self.items = items
    }

    /// Names GitHub has that the vault does not ("not in your vault: will be lost").
    public var remoteOnly: [DeletionPreviewItemModel] {
        items.filter(\.isRemoteOnly)
    }
}

/// One name in the deletion preview.
public struct DeletionPreviewItemModel: Sendable, Hashable {
    public var name: String
    public var kind: ConfigKind
    public var isInVault: Bool
    public var isOnGitHub: Bool

    public init(name: String, kind: ConfigKind, isInVault: Bool, isOnGitHub: Bool) {
        self.name = name
        self.kind = kind
        self.isInVault = isInVault
        self.isOnGitHub = isOnGitHub
    }

    public var isRemoteOnly: Bool {
        isOnGitHub && !isInVault
    }
}
