import Foundation
import VaultCore

/// Builds the receiver's import plan (§9.5). Pure: no database, no keys, no clock.
///
/// | Incoming vs local | Default | Pending |
/// |---|---|---|
/// | No local item | Add | Synced only if the sender says synced and GitHub agrees (secrets: `githubUpdatedAt` equals the listed `updatedAt`; variables: the value equals the listed value) |
/// | Local secret value missing | Fill | No if `githubUpdatedAt` equals the local `remote_updated_at`, else pending modify |
/// | Identical fingerprint | Skip | No |
/// | Different | Keep mine (Overwrite available) | Overwrite is pending modify |
/// | Same name, other kind | Skip + warning | No |
/// | Incoming value missing | Add without value if absent, else skip | No |
/// | Environment missing | Create with its policy | Pending unless GitHub lists it |
/// | Partial environment (no policy, v2) missing | Create with GitHub's policy if listed, else all branches | Pending unless GitHub lists it |
/// | Existing environment, different policy | Keep mine; widening needs a second confirmation | Only if accepted |
/// | Existing environment, partial (no policy) | Items only; the local policy is never touched | No |
///
/// Run it on the manifest for the nearby preview (Same/Differs unknown, chip
/// `existsLocally`) and again on the payload before applying.
public enum ShareImportPlanner {
    /// Glob characters GitHub honours in deployment branch patterns.
    static let wildcardCharacters: Set<Character> = ["*", "?", "["]

    /// Validates `package` for `mode` and plans it against `local`.
    public static func plan(
        _ package: SharePackageModel,
        mode: SharePackageValidator.Mode,
        local: ShareLocalStateModel,
        fingerprint: @escaping ShareFingerprinter
    ) throws(ShareError) -> ShareImportPlanModel {
        try SharePackageValidator.validate(package, mode: mode)
        // A folder is planned only once retargeted at a repository (`intoRepository`, v0.7.0).
        guard !package.isFolder else { throw .invalidPackage(.scopeMismatch(.folder)) }
        let senderName = package.sender.displayName.isEmpty ? nil : package.sender.displayName
        let origin = ShareOriginModel(packageID: package.packageID, senderName: senderName)
        let blockReason = blockReason(for: package.repository, local: local.repository)
        guard blockReason == nil else {
            return ShareImportPlanModel(
                packageID: package.packageID,
                origin: origin,
                mode: mode,
                blockReason: blockReason,
                replayWarnings: [],
                repositoryItems: [],
                environments: []
            )
        }
        let context = Context(package: package, mode: mode, local: local, fingerprint: fingerprint)
        let repositoryItems = context.planItems(package.repository.secrets, kind: .secret, environment: nil)
            + context.planItems(package.repository.variables, kind: .variable, environment: nil)
        let environments = package.repository.environments.map { context.planEnvironment($0) }
        return ShareImportPlanModel(
            packageID: package.packageID,
            origin: origin,
            mode: mode,
            blockReason: nil,
            replayWarnings: context.replayWarnings(),
            repositoryItems: repositoryItems,
            environments: environments
        )
    }

    // MARK: - Preconditions

    private static func blockReason(
        for incoming: ShareRepositoryModel,
        local: RepoModel?
    ) -> ShareImportBlockReason? {
        guard let local else { return .repositoryNotImported }
        let sameOwner = OwnerLoginValidator.foldKey(local.ownerLogin) == OwnerLoginValidator.foldKey(incoming.owner)
        let sameName = RepoNameValidator.foldKey(local.name) == RepoNameValidator.foldKey(incoming.name)
        guard sameOwner, sameName else { return .repositoryNameMismatch }
        if let incomingID = incoming.githubRepoID, incomingID != local.githubID {
            return .repositoryIDMismatch
        }
        return nil
    }

    // MARK: - Policies

    /// Whether moving from `local` to `incoming` allows deployments from more refs:
    /// anything → all, custom → protected, or added wildcard patterns.
    static func isWidening(from local: ShareBranchPolicyModel, to incoming: ShareBranchPolicyModel) -> Bool {
        switch (local.type, incoming.type) {
        case (.all, _):
            return false
        case (_, .all):
            return true
        case (.custom, .protected):
            return true
        case (.custom, .custom):
            return incoming.patternSet.subtracting(local.patternSet).contains { pattern in
                pattern.name.contains(where: wildcardCharacters.contains)
            }
        default:
            return false
        }
    }
}

// MARK: - Context

/// Lookup tables for one planning run.
private struct Context {
    let package: SharePackageModel
    let mode: SharePackageValidator.Mode
    let local: ShareLocalStateModel
    let fingerprint: ShareFingerprinter
    let environmentsByKey: [String: EnvironmentModel]
    let environmentKeysByID: [EnvironmentID: String]
    let itemsByKey: [ShareMatchKey: ShareLocalItemModel]
    let remoteItemsByKey: [ShareMatchKey: ShareRemoteItemModel]
    let remoteEnvironmentKeys: Set<String>

    init(
        package: SharePackageModel,
        mode: SharePackageValidator.Mode,
        local: ShareLocalStateModel,
        fingerprint: @escaping ShareFingerprinter
    ) {
        self.package = package
        self.mode = mode
        self.local = local
        self.fingerprint = fingerprint
        var environmentsByKey: [String: EnvironmentModel] = [:]
        for environment in local.environments {
            // A live environment wins over a tombstone with the same key.
            let key = environment.nameKey
            if environmentsByKey[key] == nil || environmentsByKey[key]?.isDeleted == true {
                environmentsByKey[key] = environment
            }
        }
        self.environmentsByKey = environmentsByKey
        let environmentKeysByID = Dictionary(
            local.environments.map { ($0.id, $0.nameKey) },
            uniquingKeysWith: { first, _ in first }
        )
        self.environmentKeysByID = environmentKeysByID
        var itemsByKey: [ShareMatchKey: ShareLocalItemModel] = [:]
        for localItem in local.items {
            let environmentKey: String
            if let environmentID = localItem.item.scope.environmentID {
                guard let key = environmentKeysByID[environmentID] else { continue }
                environmentKey = key
            } else {
                environmentKey = ""
            }
            let key = ShareMatchKey(
                environmentKey: environmentKey,
                kind: localItem.item.kind,
                nameKey: localItem.item.nameKey
            )
            if itemsByKey[key] == nil || itemsByKey[key]?.item.isDeleted == true {
                itemsByKey[key] = localItem
            }
        }
        self.itemsByKey = itemsByKey
        remoteItemsByKey = Dictionary(
            (local.remote?.items ?? []).map { ($0.key.matchKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        remoteEnvironmentKeys = Set((local.remote?.environmentNames ?? []).map(EnvironmentNameValidator.foldKey))
    }

    // MARK: Replay

    func replayWarnings() -> Set<ShareReplayWarning> {
        var warnings = Set<ShareReplayWarning>()
        if local.importedPackageIDs.contains(package.packageID) {
            warnings.insert(.alreadyImported)
        }
        if local.now.timeIntervalSince(package.createdAt) > Timeouts.shareReplayMaxAge.timeInterval {
            warnings.insert(.olderThanMaxAge)
        }
        let matchedItems = package.flattenedItems.compactMap { located in
            itemsByKey[key(for: located).matchKey]?.item.updatedAt
        }
        // A partial environment changes nothing on the environment itself, so only whole ones count.
        let matchedEnvironments = package.repository.environments.filter(\.includesBranchPolicy).compactMap { environment in
            environmentsByKey[EnvironmentNameValidator.foldKey(environment.name)]?.updatedAt
        }
        if (matchedItems + matchedEnvironments).contains(where: { $0 > package.createdAt }) {
            warnings.insert(.olderThanLocalChanges)
        }
        return warnings
    }

    // MARK: Environments

    func planEnvironment(_ environment: ShareEnvironmentModel) -> ShareEnvironmentPlanModel {
        let key = EnvironmentNameValidator.foldKey(environment.name)
        let existing = environmentsByKey[key]
        let action: ShareEnvironmentAction
        var difference: SharePolicyDifferenceModel?
        switch existing {
        case nil:
            action = .create(pending: !remoteEnvironmentKeys.contains(key))
        case .some(let localEnvironment) where localEnvironment.isDeleted:
            action = .blockedDeletedLocally
        case .some(let localEnvironment):
            action = .useExisting
            let localPolicy = ShareBranchPolicyModel(localEnvironment.branchPolicy)
            if let incoming = environment.deploymentBranchPolicy,
               localPolicy.type != incoming.type || localPolicy.patternSet != incoming.patternSet {
                difference = SharePolicyDifferenceModel(
                    localPolicy: localPolicy,
                    incomingPolicy: incoming,
                    isWidening: ShareImportPlanner.isWidening(from: localPolicy, to: incoming)
                )
            }
        }
        var items = planItems(environment.secrets, kind: .secret, environment: environment.name)
            + planItems(environment.variables, kind: .variable, environment: environment.name)
        if action == .blockedDeletedLocally {
            items = items.map { blockedByDeletion($0) }
        }
        return ShareEnvironmentPlanModel(
            id: environment.id,
            name: environment.name,
            localEnvironmentID: existing?.id,
            action: action,
            incomingPolicy: environment.deploymentBranchPolicy,
            policyDifference: difference,
            items: items
        )
    }

    private func blockedByDeletion(_ plan: ShareItemPlanModel) -> ShareItemPlanModel {
        ShareItemPlanModel(
            id: plan.id,
            key: plan.key,
            localItemID: plan.localItemID,
            chip: .deletedLocally,
            defaultAction: .skip,
            allowedActions: [.skip],
            warnings: plan.warnings.union([.deletedLocally])
        )
    }

    // MARK: Items

    func planItems(_ items: [ShareItemModel], kind: ConfigKind, environment: String?) -> [ShareItemPlanModel] {
        items.map { item in
            planItem(ShareLocatedItemModel(environmentName: environment, kind: kind, item: item))
        }
    }

    private func key(for located: ShareLocatedItemModel) -> ShareItemKeyModel {
        ShareItemKeyModel(environmentName: located.environmentName, kind: located.kind, name: located.item.name)
    }

    private func planItem(_ located: ShareLocatedItemModel) -> ShareItemPlanModel {
        let key = key(for: located)
        let incoming = located.item
        guard let localItem = itemsByKey[key.matchKey] else {
            return planNewItem(located, key: key)
        }
        var warnings = Set<ShareItemWarning>()
        if localItem.item.updatedAt > package.createdAt {
            warnings.insert(.localChangedSincePackage)
        }
        let local = localItem.item
        if local.isDeleted {
            return ShareItemPlanModel(
                id: incoming.id,
                key: key,
                localItemID: local.id,
                chip: .deletedLocally,
                defaultAction: .skip,
                allowedActions: [.skip],
                warnings: warnings.union([.deletedLocally])
            )
        }
        if incoming.valueState == .missing {
            return ShareItemPlanModel(
                id: incoming.id,
                key: key,
                localItemID: local.id,
                chip: .valueNotIncluded,
                defaultAction: .skip,
                allowedActions: [.skip],
                warnings: warnings
            )
        }
        if local.valueState == .missing {
            let fillIsSynced = incoming.githubUpdatedAt != nil && incoming.githubUpdatedAt == local.remoteUpdatedAt
            return ShareItemPlanModel(
                id: incoming.id,
                key: key,
                localItemID: local.id,
                chip: .fillsMissingValue,
                defaultAction: .fill,
                allowedActions: [.fill, .skip],
                warnings: warnings,
                fillIsSynced: fillIsSynced
            )
        }
        let chip: ShareItemChip
        switch (mode, incoming.value) {
        case (.payload, .some(let value)):
            chip = isSame(value, as: localItem) ? .same : .differs
        default:
            chip = .existsLocally
        }
        let allowed: [ShareItemAction] = chip == .same ? [.skip] : [.keepMine, .overwrite]
        return ShareItemPlanModel(
            id: incoming.id,
            key: key,
            localItemID: local.id,
            chip: chip,
            defaultAction: chip == .same ? .skip : .keepMine,
            allowedActions: allowed,
            warnings: warnings
        )
    }

    private func planNewItem(_ located: ShareLocatedItemModel, key: ShareItemKeyModel) -> ShareItemPlanModel {
        let incoming = located.item
        var otherKindKey = key.matchKey
        otherKindKey.kind = key.kind == .secret ? .variable : .secret
        if let other = itemsByKey[otherKindKey], !other.item.isDeleted {
            return ShareItemPlanModel(
                id: incoming.id,
                key: key,
                localItemID: nil,
                chip: .otherKindExists,
                defaultAction: .skip,
                allowedActions: [.skip],
                warnings: [.otherKindExists]
            )
        }
        if incoming.valueState == .missing {
            return ShareItemPlanModel(
                id: incoming.id,
                key: key,
                localItemID: nil,
                chip: .valueNotIncluded,
                defaultAction: .addWithoutValue,
                allowedActions: [.addWithoutValue, .skip]
            )
        }
        return ShareItemPlanModel(
            id: incoming.id,
            key: key,
            localItemID: nil,
            chip: .new,
            defaultAction: .add,
            allowedActions: [.add, .skip],
            addIsSynced: isAddSynced(located, key: key)
        )
    }

    /// No local item: synced only if the sender says synced and GitHub agrees.
    private func isAddSynced(_ located: ShareLocatedItemModel, key: ShareItemKeyModel) -> Bool {
        guard located.item.syncState == .synced, let remote = remoteItemsByKey[key.matchKey] else {
            return false
        }
        switch located.kind {
        case .secret:
            return located.item.githubUpdatedAt != nil && located.item.githubUpdatedAt == remote.updatedAt
        case .variable:
            guard let value = located.item.value,
                  let expected = remote.valueFingerprint,
                  let actual = fingerprint(.remote(key), value)
            else { return false }
            return Self.constantTimeEquals(expected, actual)
        }
    }

    private func isSame(_ value: SecretBytes, as local: ShareLocalItemModel) -> Bool {
        guard let stored = local.fingerprint, let incoming = fingerprint(.local(local.item), value) else {
            return false
        }
        return Self.constantTimeEquals(stored, incoming)
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        lhs.withUnsafeBytes { left in
            rhs.withUnsafeBytes { right in SecretBytes.constantTimeEquals(left, right) }
        }
    }
}
