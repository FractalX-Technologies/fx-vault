import Foundation
import VaultCore

/// Pure drift detection (tasks/todo.md §7.7): local rows against full remote re-lists.
///
/// The caller runs the pending-verification pass (§7.3 step 6) on the same re-list first and
/// passes the resulting local snapshot: rows still `verify_state = pending` are skipped here,
/// and so are the remote names they may have produced. Names our own sync deleted recently
/// (``DriftSuppressionModel``) are not reported as "remote added".
///
/// Matching (GitHub names are case-insensitive):
/// - an environment row's remote identity is its `synced_name`; a never-synced row, or the new
///   name of a pending rename, only *claims* a name (a remote environment there is a conflict);
/// - an item row's remote identity is its `synced_name` in its environment's identity; a
///   never-synced row, or the new name of a renamed row, only claims a name.
///
/// Scopes that were not listed (nil listing) produce no item findings. A repository that does
/// not exist on GitHub yet produces none at all. Findings of a deleted or added environment
/// cover its items.
public enum DriftDetector {
    public static func detect(
        local: RepoSnapshotModel,
        remote: RemoteSnapshotModel,
        suppression: DriftSuppressionModel = .none
    ) -> [DriftModel] {
        guard local.repository.existsOnGitHub else { return [] }
        var detection = Detection(local: local, remote: remote, suppression: suppression)
        detection.detectEnvironments()
        detection.detectItems(scope: .repository, environment: nil, listing: remote.repository)
        for (environment, remoteEnvironment) in detection.matchedEnvironments {
            detection.detectItems(
                scope: .environment(environment.id),
                environment: environment,
                listing: remoteEnvironment.listing
            )
        }
        return detection.findings.sorted { lhs, rhs in
            if lhs.subject.target != rhs.subject.target { return lhs.subject.target < rhs.subject.target }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    /// True when two GitHub timestamps are the same instant at the vault's stored precision
    /// (``SyncEngineConstants/timestampTolerance``). Two nils are equal; nil and a date are not.
    public static func isSameTimestamp(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (let left?, let right?): abs(left.timeIntervalSince(right)) < SyncEngineConstants.timestampTolerance
        default: false
        }
    }
}

/// One detection run.
private struct Detection {
    let local: RepoSnapshotModel
    let remote: RemoteSnapshotModel
    let suppression: DriftSuppressionModel
    private(set) var findings: [DriftModel] = []
    /// Synced, non-deleted local environments that exist remotely; their items are compared.
    private(set) var matchedEnvironments: [(EnvironmentModel, RemoteEnvironmentModel)] = []

    init(local: RepoSnapshotModel, remote: RemoteSnapshotModel, suppression: DriftSuppressionModel) {
        self.local = local
        self.remote = remote
        self.suppression = suppression
    }

    private var repositoryID: RepoID {
        local.repository.id
    }

    // MARK: - Environments

    mutating func detectEnvironments() {
        var claimed: Set<RemoteScopeKeyModel> = []
        for environment in local.environments {
            if let syncedName = environment.syncedName {
                let key = RemoteScopeKeyModel.environment(named: syncedName)
                claimed.insert(key)
                detectSyncedEnvironment(environment, remote: remote.environment(key))
            }
        }
        for remoteEnvironment in remote.environments where !claimed.contains(remoteEnvironment.scope) {
            detectUnclaimedEnvironment(remoteEnvironment)
        }
    }

    private mutating func detectSyncedEnvironment(_ environment: EnvironmentModel, remote remoteEnvironment: RemoteEnvironmentModel?) {
        guard let syncedName = environment.syncedName, !environment.isDeleted else { return }
        guard let remoteEnvironment else {
            findings.append(environmentDeleted(environment, syncedName: syncedName))
            return
        }
        matchedEnvironments.append((environment, remoteEnvironment))
        if remoteEnvironment.branchPolicy != environment.syncedBranchPolicy {
            findings.append(policyModified(environment, remote: remoteEnvironment))
        }
    }

    private mutating func detectUnclaimedEnvironment(_ remoteEnvironment: RemoteEnvironmentModel) {
        let key = remoteEnvironment.scope
        let claimant = local.environments.first { !$0.isDeleted && $0.nameKey == key.environmentKey }
        if claimant == nil, suppression.deletedEnvironments.contains(key) { return }
        findings.append(environmentAdded(remoteEnvironment, claimant: claimant))
    }

    private func environmentDeleted(_ environment: EnvironmentModel, syncedName: String) -> DriftModel {
        let children = local.items(in: .environment(environment.id))
        let isPendingLocally = environment.hasPendingRename
            || environment.hasPendingPolicyChange
            || children.contains(where: \.hasPendingChange)
        return DriftModel(
            repositoryID: repositoryID,
            kind: .environmentDeleted,
            subject: .environment(DriftEnvironmentSubjectModel(
                key: .environment(named: syncedName),
                name: syncedName,
                environmentID: environment.id,
                githubID: environment.githubEnvID,
                remotePolicy: nil
            )),
            isConflict: isPendingLocally,
            remoteUpdatedAt: nil,
            keepLocal: DriftResolutionModel(option: .keepLocal, effects: [.markEnvironmentUnsynced(environmentID: environment.id)]),
            acceptGitHub: DriftResolutionModel(option: .acceptGitHub, effects: [.deleteLocalEnvironment(environmentID: environment.id)])
        )
    }

    private func policyModified(_ environment: EnvironmentModel, remote remoteEnvironment: RemoteEnvironmentModel) -> DriftModel {
        DriftModel(
            repositoryID: repositoryID,
            kind: .environmentPolicyModified,
            subject: .environment(DriftEnvironmentSubjectModel(
                key: remoteEnvironment.scope,
                name: remoteEnvironment.name,
                environmentID: environment.id,
                githubID: remoteEnvironment.githubID,
                remotePolicy: remoteEnvironment.branchPolicy
            )),
            isConflict: environment.hasPendingPolicyChange,
            remoteUpdatedAt: remoteEnvironment.updatedAt,
            keepLocal: DriftResolutionModel(option: .keepLocal, effects: [
                .rebaseEnvironmentPolicy(environmentID: environment.id, remotePolicy: remoteEnvironment.branchPolicy),
            ]),
            acceptGitHub: DriftResolutionModel(option: .acceptGitHub, effects: [
                .adoptRemoteEnvironmentPolicy(environmentID: environment.id, remotePolicy: remoteEnvironment.branchPolicy),
            ])
        )
    }

    private func environmentAdded(_ remoteEnvironment: RemoteEnvironmentModel, claimant: EnvironmentModel?) -> DriftModel {
        let subject = DriftEnvironmentSubjectModel(
            key: remoteEnvironment.scope,
            name: remoteEnvironment.name,
            environmentID: claimant?.id,
            githubID: remoteEnvironment.githubID,
            remotePolicy: remoteEnvironment.branchPolicy,
            remoteItemNames: (remoteEnvironment.listing?.items.map(\.name) ?? []).sorted()
        )
        let keepLocal: DriftResolutionModel
        let acceptGitHub: DriftResolutionModel
        switch claimant {
        case nil:
            keepLocal = DriftResolutionModel(option: .keepLocal, effects: [
                .createEnvironmentTombstone(name: remoteEnvironment.name, githubID: remoteEnvironment.githubID),
            ])
            acceptGitHub = DriftResolutionModel(option: .acceptGitHub, effects: [
                .importEnvironment(
                    name: remoteEnvironment.name,
                    githubID: remoteEnvironment.githubID,
                    policy: remoteEnvironment.branchPolicy
                ),
            ])
        case let claimant? where claimant.isSynced:
            // The new name of a pending rename already exists on GitHub.
            keepLocal = .unavailable(.keepLocal, .conflictsWithPendingRename)
            acceptGitHub = .unavailable(.acceptGitHub, .conflictsWithPendingRename)
        case let claimant?:
            keepLocal = DriftResolutionModel(option: .keepLocal, effects: [
                .adoptRemoteEnvironment(
                    environmentID: claimant.id,
                    remoteName: remoteEnvironment.name,
                    githubID: remoteEnvironment.githubID,
                    remotePolicy: remoteEnvironment.branchPolicy,
                    adoptPolicy: false
                ),
            ])
            acceptGitHub = DriftResolutionModel(option: .acceptGitHub, effects: [
                .adoptRemoteEnvironment(
                    environmentID: claimant.id,
                    remoteName: remoteEnvironment.name,
                    githubID: remoteEnvironment.githubID,
                    remotePolicy: remoteEnvironment.branchPolicy,
                    adoptPolicy: true
                ),
            ])
        }
        return DriftModel(
            repositoryID: repositoryID,
            kind: .environmentAdded,
            subject: .environment(subject),
            isConflict: claimant != nil,
            remoteUpdatedAt: remoteEnvironment.updatedAt,
            keepLocal: keepLocal,
            acceptGitHub: acceptGitHub
        )
    }

    // MARK: - Items

    mutating func detectItems(scope: ConfigScope, environment: EnvironmentModel?, listing: RemoteScopeListingModel?) {
        guard let listing else { return }
        let remoteScope = environment.flatMap { $0.syncedName.map(RemoteScopeKeyModel.environment(named:)) } ?? .repository
        let rows = local.items(in: scope)
        var claimed: Set<RemoteItemKeyModel> = []
        var claimants: [RemoteItemKeyModel: ConfigItemSnapshotModel] = [:]

        for row in rows {
            let desiredKey = RemoteItemKeyModel(scope: remoteScope, kind: row.kind, name: row.name)
            guard let syncedName = row.syncedName else {
                if !row.isDeleted { claimants[desiredKey] = row }
                continue
            }
            let identity = RemoteItemKeyModel(scope: remoteScope, kind: row.kind, name: syncedName)
            claimed.insert(identity)
            if !row.isDeleted, row.isRenamed {
                claimants[desiredKey] = row
            }
            guard row.verifyState != .pending else { continue }
            let context = ItemContext(row: row, key: identity, environment: environment)
            if let remoteItem = listing.item(kind: row.kind, nameKey: identity.nameKey) {
                detectModified(context, remote: remoteItem)
            } else if !row.isDeleted {
                findings.append(remoteDeleted(context))
            }
        }

        for remoteItem in listing.items {
            let key = RemoteItemKeyModel(scope: remoteScope, kind: remoteItem.kind, name: remoteItem.name)
            guard !claimed.contains(key) else { continue }
            let claimant = claimants[key]
            if let claimant, claimant.verifyState == .pending { continue }
            if claimant == nil, suppression.deletedItems.contains(key) { continue }
            findings.append(remoteAdded(remoteItem, key: key, environment: environment, claimant: claimant))
        }
    }

    private struct ItemContext {
        var row: ConfigItemSnapshotModel
        var key: RemoteItemKeyModel
        var environment: EnvironmentModel?

        func subject(name: String) -> DriftItemSubjectModel {
            DriftItemSubjectModel(
                key: key,
                kind: row.kind,
                name: name,
                environmentName: environment?.syncedName,
                environmentID: environment?.id,
                itemID: row.id
            )
        }
    }

    private mutating func detectModified(_ context: ItemContext, remote remoteItem: RemoteItemModel) {
        let row = context.row
        switch remoteItem {
        case .variable(let variable):
            guard let remoteFingerprint = variable.fingerprint(for: row.id),
                  remoteFingerprint != row.syncedFingerprint
            else { return }
            findings.append(DriftModel(
                repositoryID: repositoryID,
                kind: .variableModified,
                subject: .item(context.subject(name: variable.name)),
                isConflict: row.hasPendingChange,
                remoteUpdatedAt: variable.updatedAt,
                keepLocal: DriftResolutionModel(option: .keepLocal, effects: [
                    .rebaseVariable(itemID: row.id, remoteFingerprint: remoteFingerprint),
                ]),
                acceptGitHub: DriftResolutionModel(option: .acceptGitHub, effects: [
                    .adoptRemoteVariable(itemID: row.id, remoteFingerprint: remoteFingerprint),
                ])
            ))
        case .secret(let secret):
            guard !DriftDetector.isSameTimestamp(secret.updatedAt, row.remoteUpdatedAt) else { return }
            let keepLocal: DriftResolutionModel = if row.isDeleted || row.hasValue {
                DriftResolutionModel(option: .keepLocal, effects: [
                    .rebaseSecret(itemID: row.id, remoteUpdatedAt: secret.updatedAt, forcePush: !row.isDeleted),
                ])
            } else {
                .unavailable(.keepLocal, .valueMissing)
            }
            findings.append(DriftModel(
                repositoryID: repositoryID,
                kind: .secretModified,
                subject: .item(context.subject(name: secret.name)),
                isConflict: row.hasPendingChange,
                remoteUpdatedAt: secret.updatedAt,
                keepLocal: keepLocal,
                acceptGitHub: DriftResolutionModel(
                    option: .acceptGitHub,
                    effects: [.clearSecretValue(itemID: row.id, remoteUpdatedAt: secret.updatedAt)],
                    followUp: .promptFillValue(row.id)
                )
            ))
        }
    }

    private func remoteDeleted(_ context: ItemContext) -> DriftModel {
        let row = context.row
        let keepLocal: DriftResolutionModel = row.hasValue
            ? DriftResolutionModel(option: .keepLocal, effects: [.markItemUnsynced(itemID: row.id)])
            : .unavailable(.keepLocal, .valueMissing)
        return DriftModel(
            repositoryID: repositoryID,
            kind: .remoteDeleted,
            subject: .item(context.subject(name: row.syncedName ?? row.name)),
            isConflict: row.hasPendingChange,
            remoteUpdatedAt: nil,
            keepLocal: keepLocal,
            acceptGitHub: DriftResolutionModel(option: .acceptGitHub, effects: [.deleteLocalItem(itemID: row.id)])
        )
    }

    private func remoteAdded(
        _ remoteItem: RemoteItemModel,
        key: RemoteItemKeyModel,
        environment: EnvironmentModel?,
        claimant: ConfigItemSnapshotModel?
    ) -> DriftModel {
        let subject = DriftItemSubjectModel(
            key: key,
            kind: remoteItem.kind,
            name: remoteItem.name,
            environmentName: environment?.syncedName,
            environmentID: environment?.id,
            itemID: claimant?.id
        )
        let resolutions = claimant.map { conflictResolutions($0, remote: remoteItem) }
            ?? newItemResolutions(remoteItem, environment: environment)
        return DriftModel(
            repositoryID: repositoryID,
            kind: .remoteAdded,
            subject: .item(subject),
            isConflict: claimant != nil,
            remoteUpdatedAt: remoteItem.updatedAt,
            keepLocal: resolutions.keepLocal,
            acceptGitHub: resolutions.acceptGitHub
        )
    }

    private func newItemResolutions(
        _ remoteItem: RemoteItemModel,
        environment: EnvironmentModel?
    ) -> (keepLocal: DriftResolutionModel, acceptGitHub: DriftResolutionModel) {
        let placement = DriftItemPlacementModel(
            environmentID: environment?.id,
            kind: remoteItem.kind,
            name: remoteItem.name,
            remoteUpdatedAt: remoteItem.updatedAt
        )
        return (
            DriftResolutionModel(option: .keepLocal, effects: [.createTombstone(placement)]),
            DriftResolutionModel(option: .acceptGitHub, effects: [.importItem(placement)])
        )
    }

    /// A never-synced row (or the new name of a renamed row) whose name GitHub already has.
    private func conflictResolutions(
        _ row: ConfigItemSnapshotModel,
        remote remoteItem: RemoteItemModel
    ) -> (keepLocal: DriftResolutionModel, acceptGitHub: DriftResolutionModel) {
        let detach: [DriftEffectModel] = row.isSynced ? [.detachSyncedIdentity(itemID: row.id)] : []
        let remoteFingerprint: Data? = if case .variable(let variable) = remoteItem {
            variable.fingerprint(for: row.id)
        } else {
            nil
        }
        let keepLocal: DriftResolutionModel = row.hasValue
            ? DriftResolutionModel(option: .keepLocal, effects: detach + [
                .adoptRemoteIdentity(
                    itemID: row.id,
                    remoteName: remoteItem.name,
                    remoteUpdatedAt: remoteItem.updatedAt,
                    remoteFingerprint: remoteFingerprint
                ),
            ])
            : .unavailable(.keepLocal, .valueMissing)
        let acceptGitHub = DriftResolutionModel(
            option: .acceptGitHub,
            effects: detach + [
                .replaceWithRemote(
                    itemID: row.id,
                    remoteName: remoteItem.name,
                    remoteUpdatedAt: remoteItem.updatedAt,
                    remoteFingerprint: remoteFingerprint
                ),
            ],
            followUp: remoteItem.kind == .secret ? .promptFillValue(row.id) : nil
        )
        return (keepLocal, acceptGitHub)
    }
}
