import Foundation
import VaultCore

/// Builds the §7.2 summary from normalized change sets. Names only, never values.
///
/// - Item sets are shown as added (`isNew`), renamed (the new half of a rename; its delete is
///   folded into it) or modified (an update, including a set that normalization merged with a
///   delete). Items an environment rename copies are part of the rename line.
/// - Item deletes are shown as deleted. Items of a deleted environment are not listed (the
///   deletion confirmation fetches them live, §7.5).
/// - Blocked changes go to ``RepoChangeSummaryModel/blocked``, except
///   ``ChangeBlockReason/remoteChanged`` ones, which go to
///   ``RepoChangeSummaryModel/remoteChanged``; changes blocked only because they depend on
///   another blocked change are folded into it.
public enum ChangeSummaryBuilder {
    /// The summary of several repositories, in the given order.
    public static func summarize(_ changeSets: [ChangeSetModel], writeBudget: WriteBudgetModel? = nil) -> ChangeSummaryModel {
        ChangeSummaryModel(repositories: changeSets.map(summarize), writeBudget: writeBudget)
    }

    /// One repository's block.
    public static func summarize(_ changeSet: ChangeSetModel) -> RepoChangeSummaryModel {
        var scopes: [RemoteScopeKeyModel: ScopeAccumulator] = [:]
        var newRepository: NewRepositorySummaryModel?
        for change in changeSet.changes {
            if case .createRepository(let create) = change.operation {
                newRepository = NewRepositorySummaryModel(
                    visibility: create.visibility,
                    addsReadme: create.spec?.autoInit ?? false,
                    gitignoreTemplate: create.spec?.gitignoreTemplate,
                    licenseTemplate: create.spec?.licenseTemplate
                )
                continue
            }
            scopes[change.scope, default: ScopeAccumulator(scope: change.scope)].add(change)
        }
        var blocked: [BlockedSummaryModel] = []
        var remoteChanged: [RemoteChangedSummaryModel] = []
        for entry in changeSet.blocked {
            guard let subject = BlockedSubject(entry.change) else { continue }
            switch entry.reason {
            case .dependsOn:
                continue
            case .remoteChanged:
                remoteChanged.append(RemoteChangedSummaryModel(name: subject.name, kind: subject.kind, scope: subject.scope))
            case .valueMissing, .renameNeedsValues:
                blocked.append(BlockedSummaryModel(name: subject.name, kind: subject.kind, scope: subject.scope, reason: entry.reason))
            }
        }
        return RepoChangeSummaryModel(
            id: changeSet.repository.id,
            fullName: changeSet.repository.fullName,
            newRepository: newRepository,
            scopes: scopes.values.compactMap(\.model).sorted { $0.scope < $1.scope },
            blocked: blocked,
            remoteChanged: remoteChanged,
            pendingCount: changeSet.pendingCount,
            notes: changeSet.notes
        )
    }
}

/// Name, kind and scope of a blocked change, for display.
private struct BlockedSubject {
    var name: String
    var kind: ConfigKind?
    var scope: ScopeLabelModel

    init?(_ change: ConfigChangeModel) {
        switch change.operation {
        case .createRepository:
            return nil
        case .upsertEnvironment(let upsert):
            self.init(name: upsert.name, kind: nil, scope: .environment(upsert.name))
        case .renameEnvironment(let rename):
            self.init(name: rename.fromName, kind: nil, scope: .environment(rename.toName))
        case .reconcileBranchPatterns(let reconcile):
            self.init(name: reconcile.environmentName, kind: nil, scope: .environment(reconcile.environmentName))
        case .deleteEnvironment(let delete):
            self.init(name: delete.name, kind: nil, scope: .environment(delete.name))
        case .setItem(let set):
            self.init(name: set.name, kind: set.kind, scope: set.environmentName.map(ScopeLabelModel.environment) ?? .repository)
        case .deleteItem(let delete):
            self.init(name: delete.name, kind: delete.kind, scope: delete.environmentName.map(ScopeLabelModel.environment) ?? .repository)
        }
    }

    init(name: String, kind: ConfigKind?, scope: ScopeLabelModel) {
        self.name = name
        self.kind = kind
        self.scope = scope
    }
}

/// Collects one scope's line.
private struct ScopeAccumulator {
    let scope: RemoteScopeKeyModel
    var label: ScopeLabelModel?
    var environmentChange: EnvironmentChangeSummaryModel?
    var policy: PolicySummaryModel?
    var items: [ItemChangeSummaryModel] = []

    init(scope: RemoteScopeKeyModel) {
        self.scope = scope
    }

    mutating func add(_ change: ConfigChangeModel) {
        switch change.operation {
        case .createRepository:
            break
        case .upsertEnvironment(let upsert):
            label = .environment(upsert.name)
            environmentChange = upsert.isNew ? .created : .policyChanged
            if !upsert.isNew || upsert.policy.kind != .all {
                policy = Self.policy(upsert.policy)
            }
        case .renameEnvironment(let rename):
            label = .environment(rename.toName)
            environmentChange = .renamed(from: rename.fromName)
            if rename.policy.kind != .all {
                policy = Self.policy(rename.policy)
            }
        case .reconcileBranchPatterns(let reconcile):
            label = label ?? .environment(reconcile.environmentName)
            policy = PolicySummaryModel(kind: .custom, patterns: reconcile.desired.map(\.pattern))
        case .deleteEnvironment(let delete):
            label = .environment(delete.name)
            environmentChange = .deleted
        case .setItem(let set):
            label = label ?? (set.environmentName.map(ScopeLabelModel.environment) ?? .repository)
            if let item = Self.summary(of: set) { items.append(item) }
        case .deleteItem(let delete):
            label = label ?? (delete.environmentName.map(ScopeLabelModel.environment) ?? .repository)
            if case .renamed = delete.reason { return }
            items.append(ItemChangeSummaryModel(name: delete.name, kind: delete.kind, change: .deleted))
        }
    }

    var model: ScopeChangeSummaryModel? {
        guard let label, environmentChange != nil || policy != nil || !items.isEmpty else { return nil }
        return ScopeChangeSummaryModel(
            scope: scope,
            label: label,
            environmentChange: environmentChange,
            policy: policy,
            items: items.sorted { lhs, rhs in
                if lhs.change.displayRank != rhs.change.displayRank {
                    return lhs.change.displayRank < rhs.change.displayRank
                }
                return lhs.name < rhs.name
            }
        )
    }

    private static func summary(of set: ItemSetChangeModel) -> ItemChangeSummaryModel? {
        let change: ItemChangeSummaryModel.Change
        switch set.reason {
        case .copiedForEnvironmentRename:
            return nil
        case .renamed(let from):
            change = .renamed(from: from)
        case .added:
            change = set.isNew ? .added : .modified
        case .modified, .forcePushed:
            change = .modified
        }
        return ItemChangeSummaryModel(name: set.name, kind: set.kind, change: change)
    }

    private static func policy(_ policy: DeploymentBranchPolicyModel) -> PolicySummaryModel {
        PolicySummaryModel(kind: policy.kind, patterns: policy.activePatterns.map(\.pattern))
    }
}
