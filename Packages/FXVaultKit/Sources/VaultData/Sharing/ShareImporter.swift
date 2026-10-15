import Foundation
import GitHubKit
import SharingKit
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// Applies a reviewed `ShareImportPlanModel` to the vault in the caller's single
/// `VaultSession.write` transaction (§9.5).
///
/// - Environments first: created with the incoming policy (as synced when GitHub already lists
///   them), or given the incoming policy when the user accepted a "Deployment branches differ"
///   row. A partial environment (no incoming policy, schema v2) never changes an existing
///   policy; when it is missing locally it is created with GitHub's policy and patterns when
///   GitHub lists it (fully synced, nothing pending), otherwise with all branches (GitHub's
///   default for a new environment, pending create). A missing partial environment whose items
///   are all skipped is not created (``ShareEnvironmentPlanModel/createsEnvironment``).
/// - Items through ``ItemEditBatch`` (the §7.1 editing rules, capability and capacity checks):
///   add, fill (as already on GitHub, or pushed on the next Sync) and overwrite (a pending
///   modify). Every value is normalized on entry (D32) and sealed with the **receiver's** keys
///   under the receiver's row ids.
/// - Then every changed row gets `provenance = share` with the package id and the unverified
///   sender name; an add the planner found already on GitHub is marked synced; an incoming
///   secret without a value is added value-missing.
/// - Finally the package id is recorded for the replay check.
struct ShareImporter {
    let database: VaultDatabase
    let tx: StoreTransaction
    let keys: UnlockedKeys
    let now: Date
    let writePolicy: WriteCollaboratorPolicy

    private enum Adjustment {
        case provenance
        case syncedAdd(githubUpdatedAt: Date?)
    }

    func apply(
        _ plan: ShareImportPlanModel,
        package: SharePackageModel,
        remote: ShareRemoteContextModel?
    ) throws -> ShareImportResultModel {
        if let reason = plan.blockReason { throw SharingError.importBlocked(reason) }
        guard let repository = try RepoStore(database: database).fetch(
            ownerLogin: package.repository.owner,
            name: package.repository.name,
            in: tx
        ) else { throw SharingError.importBlocked(.repositoryNotImported) }
        var result = ShareImportResultModel(repositoryID: repository.id)
        let store = ConfigStore(database: database)

        let scopes = try applyEnvironments(plan, repository: repository, remote: remote, store: store, result: &result)

        let incoming = Dictionary(package.flattenedItems.map { ($0.item.id, $0.item) }, uniquingKeysWith: { first, _ in first })
        var batch = try ItemEditBatch(
            repositoryID: repository.id,
            keys: keys,
            tx: tx,
            store: store,
            now: now,
            writePolicy: writePolicy
        )
        var adjustments: [(ConfigItemID, Adjustment)] = []
        var valueMissing: [(ConfigScope, ShareItemModel)] = []
        let located = plan.repositoryItems.map { (scope: ConfigScope?.some(.repository), plan: $0) }
            + plan.environments.flatMap { environment in environment.items.map { (scope: scopes[environment.id], plan: $0) } }
        for (scope, itemPlan) in located {
            let outcome = itemPlan.outcome
            guard outcome != .unchanged, let scope else { continue }
            guard let item = incoming[itemPlan.id] else { throw SharingError.planOutdated }
            let label = Self.label(itemPlan.key)
            switch outcome {
            case .unchanged:
                continue
            case .addedWithoutValue:
                guard itemPlan.key.kind == .secret else {
                    result.skippedVariablesWithoutValue.append(label)
                    continue
                }
                valueMissing.append((scope, item))
                result.addedWithoutValue.append(label)
            case .added(let pending):
                let value = try normalizedValue(of: item, label: label, result: &result)
                defer { value.wipe() }
                let id = try batch.add(scope: scope, kind: itemPlan.key.kind, name: item.name, value: value)
                adjustments.append((id, pending ? .provenance : .syncedAdd(githubUpdatedAt: item.githubUpdatedAt)))
                result.added.append(label)
            case .filled(let pending):
                guard let localID = itemPlan.localItemID else { throw SharingError.planOutdated }
                let value = try normalizedValue(of: item, label: label, result: &result)
                defer { value.wipe() }
                try batch.fill(localID, value: value, pushOnNextSync: pending)
                adjustments.append((localID, .provenance))
                result.filled.append(label)
            case .overwritten:
                guard let localID = itemPlan.localItemID else { throw SharingError.planOutdated }
                let value = try normalizedValue(of: item, label: label, result: &result)
                defer { value.wipe() }
                try batch.editValue(localID, value: value)
                adjustments.append((localID, .provenance))
                result.overwritten.append(label)
            }
        }

        let origin = plan.origin
        for (id, adjustment) in adjustments {
            try markShared(id, adjustment: adjustment, origin: origin, store: store)
        }
        for (scope, item) in valueMissing {
            let record = ConfigItemRecord(
                repositoryID: repository.id,
                scope: scope,
                kind: .secret,
                name: item.name,
                valueCiphertext: nil,
                valueFingerprint: nil,
                syncedName: item.name,
                remoteUpdatedAt: item.githubUpdatedAt,
                provenance: .share,
                shareOrigin: origin,
                createdAt: now,
                updatedAt: now
            )
            try store.insertItem(record, in: tx)
        }
        try SharePackageStore(database: database).recordImport(
            ImportedSharePackageRecord(
                packageID: package.packageID,
                createdAt: package.createdAt,
                importedAt: now,
                senderName: origin.senderName
            ),
            in: tx
        )
        return result
    }

    // MARK: - Environments

    /// Creates or updates the plan's environments; returns the local scope of every environment
    /// plan whose items may be imported.
    private func applyEnvironments(
        _ plan: ShareImportPlanModel,
        repository: RepoModel,
        remote: ShareRemoteContextModel?,
        store: ConfigStore,
        result: inout ShareImportResultModel
    ) throws -> [ShareEntryID: ConfigScope] {
        let editor = EnvironmentEditor(store: store, tx: tx, now: now, writePolicy: writePolicy)
        var scopes: [ShareEntryID: ConfigScope] = [:]
        for environment in plan.environments {
            switch environment.action {
            case .create(let pending):
                // A partial environment whose items are all skipped says nothing: not created,
                // so its items have no scope and nothing in it is imported.
                guard environment.createsEnvironment else { continue }
                let key = EnvironmentNameValidator.foldKey(environment.name)
                let listing = pending ? nil : remote?.environments[key]
                let listedPatterns = remote?.patterns[key] ?? []
                let policy = environment.incomingPolicy.map(Self.draft)
                    ?? listing.map { Self.draft(listed: $0.branchPolicyKind, patterns: listedPatterns) }
                    ?? .all
                let id = try editor.create(in: repository.id, name: environment.name, policy: policy)
                if let listing {
                    try markSynced(id, listing: listing, store: store)
                    if !environment.includesBranchPolicy {
                        try markPatternsSynced(id, listed: listedPatterns, store: store)
                    }
                }
                scopes[environment.id] = .environment(id)
                result.environmentsCreated.append(environment.name)
            case .useExisting:
                guard let id = environment.localEnvironmentID else { throw SharingError.planOutdated }
                scopes[environment.id] = .environment(id)
                if environment.policyDifference?.decision == .useIncoming, let incoming = environment.incomingPolicy {
                    try editor.updatePolicy(id, to: Self.draft(incoming))
                    result.policiesChanged.append(environment.name)
                }
            case .blockedDeletedLocally:
                continue
            }
        }
        return scopes
    }

    /// An environment GitHub already lists (B3): created locally as synced, so only a policy
    /// difference is pending.
    private func markSynced(_ id: EnvironmentID, listing: GHEnvironmentDTO, store: ConfigStore) throws {
        guard var environment = try store.fetchEnvironment(id: id, in: tx) else { return }
        environment.syncedName = listing.name
        environment.githubEnvID = listing.id
        environment.syncedBranchPolicy = listing.branchPolicyKind
        environment.foreignRulesJSON = listing.foreignRulesJSON
        environment.remoteUpdatedAt = listing.updatedAt
        try store.updateEnvironment(environment, in: tx)
    }

    /// Gives the created environment's patterns GitHub's policy ids, so a policy copied from
    /// GitHub's listing is not pushed again.
    private func markPatternsSynced(_ id: EnvironmentID, listed: [GHBranchPolicyDTO], store: ConfigStore) throws {
        let listedIDs = Dictionary(
            listed.map { (BranchPatternKey(pattern: $0.name, type: $0.type), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        for var pattern in try store.fetchPatterns(environmentID: id, in: tx) {
            guard let githubID = listedIDs[BranchPatternKey(pattern: pattern.pattern, type: pattern.type)] else { continue }
            pattern.githubPolicyID = githubID
            try store.updatePattern(pattern, in: tx)
        }
    }

    private struct BranchPatternKey: Hashable {
        let pattern: String
        let type: BranchPatternType
    }

    /// GitHub's listed policy as a draft (patterns only for `custom`).
    static func draft(listed kind: BranchPolicyKind, patterns: [GHBranchPolicyDTO]) -> BranchPolicyDraftModel {
        switch kind {
        case .all: .all
        case .protected: .protectedBranches
        case .custom: .custom(patterns.map { BranchPatternDraftModel(pattern: $0.name, type: $0.type) })
        }
    }

    static func draft(_ policy: ShareBranchPolicyModel) -> BranchPolicyDraftModel {
        switch policy.type {
        case .all: .all
        case .protected: .protectedBranches
        case .custom: .custom(policy.patterns.map { BranchPatternDraftModel(pattern: $0.name, type: $0.type) })
        }
    }

    // MARK: - Items

    /// The incoming value normalized (D32). The caller wipes it.
    private func normalizedValue(
        of item: ShareItemModel,
        label: String,
        result: inout ShareImportResultModel
    ) throws -> SecretBytes {
        guard let value = item.value else { throw SharingError.planOutdated }
        let normalized = try ValueNormalizer.normalize(value)
        if normalized.didStripTrailingNewlines {
            result.strippedTrailingNewlines.append(label)
        }
        return normalized.value
    }

    /// `provenance = share` with the package origin; an add GitHub already has becomes synced
    /// (`synced_name`, synced value, `remote_updated_at`).
    private func markShared(
        _ id: ConfigItemID,
        adjustment: Adjustment,
        origin: ShareOriginModel,
        store: ConfigStore
    ) throws {
        guard var record = try store.fetchItemRecord(id: id, in: tx) else { throw SharingError.planOutdated }
        record.provenance = .share
        record.shareOrigin = origin
        if case .syncedAdd(let githubUpdatedAt) = adjustment {
            record.syncedName = record.name
            record.remoteUpdatedAt = githubUpdatedAt
            record.verifyState = .verified
            if let value = try ConfigFieldCipher.openValue(of: record, keys: keys) {
                defer { value.wipe() }
                try ConfigFieldCipher.setSyncedValue(value, on: &record, keys: keys)
            }
        }
        record.updatedAt = now
        try store.updateItem(record, in: tx)
    }

    /// `NAME` or `environment/NAME` (names only, for the result list).
    static func label(_ key: ShareItemKeyModel) -> String {
        key.environmentName.map { "\($0)/\(key.name)" } ?? key.name
    }
}
