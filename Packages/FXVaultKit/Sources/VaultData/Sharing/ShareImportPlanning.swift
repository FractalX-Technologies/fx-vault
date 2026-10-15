import Foundation
import GitHubKit
import SharingKit
import VaultCore
import VaultCrypto
import VaultStore

/// The receiver's inputs to `ShareImportPlanner` (§9.5): the local state (snapshots and stored
/// fingerprints, never values), GitHub's listing when one is available, and the keyed
/// fingerprinter that compares incoming values with local and listed ones.
enum ShareImportPlanning {
    /// The local state of the package's repository, read inside the caller's transaction.
    ///
    /// - Parameter importedPackageIDs: `imported_share_packages` (read in the same transaction
    ///   when applying, so the replay check cannot race another import).
    static func localState(
        for repository: ShareRepositoryModel,
        database: VaultDatabase,
        tx: StoreTransaction,
        remote: ShareRemoteContextModel?,
        importedPackageIDs: Set<SharePackageID>,
        now: Date
    ) throws -> ShareLocalStateModel {
        guard let local = try RepoStore(database: database).fetch(ownerLogin: repository.owner, name: repository.name, in: tx) else {
            return ShareLocalStateModel(repository: nil, importedPackageIDs: importedPackageIDs, now: now)
        }
        let config = ConfigStore(database: database)
        return ShareLocalStateModel(
            repository: local,
            environments: try config.fetchEnvironments(repositoryID: local.id, in: tx),
            items: try config.fetchItemStates(repositoryID: local.id, in: tx).map {
                ShareLocalItemModel(item: $0.model, fingerprint: $0.valueFingerprint)
            },
            remote: remote?.snapshot,
            importedPackageIDs: importedPackageIDs,
            now: now
        )
    }

    /// Fingerprints an incoming value for a local row (comparable with its `value_fp`) or for a
    /// listed remote variable (comparable with the listing's fingerprint). Incoming values are
    /// compared after D32 normalization, which is how they would be stored.
    static func fingerprinter(keys: UnlockedKeys, remote: ShareRemoteContextModel?) -> ShareFingerprinter {
        let rowIDs = remote?.rowIDs ?? [:]
        return { subject, value in
            let rowID: ConfigItemID
            switch subject {
            case .local(let item):
                rowID = item.id
            case .remote(let key):
                guard let id = rowIDs[ShareRemoteKeyModel(key)] else { return nil }
                rowID = id
            }
            let normalized = normalizedCopy(value)
            defer { normalized.wipe() }
            return keys.fingerprint(normalized, rowID: rowID)
        }
    }

    /// GitHub's listing of the repository for the planner: environment names, secrets with
    /// `updatedAt`, and variables fingerprinted (normalized, D32) under a random row id per
    /// listed name. Listed values are wiped by the caller (`RemoteRepoConfigModel.wipe()`).
    static func remoteContext(_ listed: RemoteRepoConfigModel, keys: borrowing UnlockedKeys) -> ShareRemoteContextModel {
        var items: [ShareRemoteItemModel] = []
        var rowIDs: [ShareRemoteKeyModel: ConfigItemID] = [:]
        func add(
            secrets: [GHSecretDTO],
            variables: [GHVariableListingModel],
            environmentName: String?,
            keys: borrowing UnlockedKeys
        ) {
            for secret in secrets {
                items.append(ShareRemoteItemModel(
                    key: ShareItemKeyModel(environmentName: environmentName, kind: .secret, name: secret.name),
                    updatedAt: secret.updatedAt
                ))
            }
            for variable in variables {
                let rowID = ConfigItemID()
                rowIDs[ShareRemoteKeyModel(environmentName: environmentName, kind: .variable, name: variable.name)] = rowID
                let normalized = normalizedCopy(variable.value)
                defer { normalized.wipe() }
                items.append(ShareRemoteItemModel(
                    key: ShareItemKeyModel(environmentName: environmentName, kind: .variable, name: variable.name),
                    updatedAt: variable.updatedAt,
                    valueFingerprint: keys.fingerprint(normalized, rowID: rowID)
                ))
            }
        }
        add(secrets: listed.secrets, variables: listed.variables, environmentName: nil, keys: keys)
        for environment in listed.environments {
            add(secrets: environment.secrets, variables: environment.variables, environmentName: environment.name, keys: keys)
        }
        return ShareRemoteContextModel(
            snapshot: ShareRemoteSnapshotModel(environmentNames: listed.environments.map(\.name), items: items),
            rowIDs: rowIDs,
            environments: Dictionary(
                listed.environments.map { (EnvironmentNameValidator.foldKey($0.name), $0.listing) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    /// `package` with every value in a new buffer, so the copy can be wiped independently.
    static func copyingValues(of package: SharePackageModel) -> SharePackageModel {
        func copied(_ items: [ShareItemModel]) -> [ShareItemModel] {
            items.map { item in
                var copy = item
                copy.value = item.value?.copy()
                return copy
            }
        }
        var copy = package
        copy.repository.secrets = copied(package.repository.secrets)
        copy.repository.variables = copied(package.repository.variables)
        copy.repository.environments = package.repository.environments.map { environment in
            var copyEnvironment = environment
            copyEnvironment.secrets = copied(environment.secrets)
            copyEnvironment.variables = copied(environment.variables)
            return copyEnvironment
        }
        return copy
    }

    /// `value` without trailing CR/LF, in a new buffer the caller wipes.
    static func normalizedCopy(_ value: SecretBytes) -> SecretBytes {
        let keptCount = value.withUnsafeBytes { $0.count - ValueNormalizer.trailingNewlineCount(in: $0) }
        return value.prefix(keptCount)
    }

    /// True when `fresh` (planned now) shows the same preview as `reviewed` (what the user saw):
    /// same items with the same chips and local rows, same environment actions and policy
    /// differences. The user's selections are only valid for that preview.
    static func isSamePreview(_ fresh: ShareImportPlanModel, as reviewed: ShareImportPlanModel) -> Bool {
        guard fresh.packageID == reviewed.packageID,
              fresh.blockReason == reviewed.blockReason,
              fresh.replayWarnings == reviewed.replayWarnings
        else { return false }
        guard previews(fresh) == previews(reviewed), fresh.environments.count == reviewed.environments.count else { return false }
        for (left, right) in zip(fresh.environments, reviewed.environments) {
            guard left.id == right.id,
                  left.action == right.action,
                  left.localEnvironmentID == right.localEnvironmentID,
                  left.policyDifference?.localPolicy == right.policyDifference?.localPolicy,
                  left.policyDifference?.incomingPolicy == right.policyDifference?.incomingPolicy
            else { return false }
        }
        return true
    }

    private static func previews(_ plan: ShareImportPlanModel) -> [ShareEntryID: ItemPreview] {
        Dictionary(plan.allItems.map { ($0.id, ItemPreview($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The parts of an item plan the user's choice depends on.
    private struct ItemPreview: Hashable {
        let chip: ShareItemChip
        let localItemID: ConfigItemID?
        let allowedActions: [ShareItemAction]

        init(_ plan: ShareItemPlanModel) {
            chip = plan.chip
            localItemID = plan.localItemID
            allowedActions = plan.allowedActions
        }
    }
}
