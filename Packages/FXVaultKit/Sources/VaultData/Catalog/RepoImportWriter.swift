import Foundation
import GitHubKit
import VaultCore
import VaultCrypto
import VaultStore

/// Stores one imported repository in the caller's `VaultSession.write` transaction (M2, §6).
///
/// - The account row is created if gh listed the repository through an account the vault does
///   not know yet.
/// - Environments are synced as listed: `synced_name = name`, `synced_branch_policy = policy`,
///   GitHub's id and `updated_at`, foreign rules as read-only JSON, and the custom patterns
///   with their GitHub policy ids.
/// - Secrets are value-missing (`value_ct IS NULL`, §7.8) with `remote_updated_at` = the listed
///   `updatedAt`, the baseline secret drift compares against (D13).
/// - Variables are sealed under the row's identity, and the synced snapshot is the same value
///   (`synced_value_ct`, `synced_fp`), so nothing is pending. Values are stored as listed (D32).
/// - Every item has `provenance = github`.
struct RepoImportWriter {
    let database: VaultDatabase
    let now: Date

    func store(
        _ repo: RepoModel,
        remote: RemoteRepoConfigModel,
        keys: borrowing UnlockedKeys,
        in tx: StoreTransaction
    ) throws {
        let accounts = AccountStore(database: database)
        if try accounts.fetch(login: repo.accountLogin, in: tx) == nil {
            try accounts.save(AccountModel(login: repo.accountLogin, lastSeenAt: now), in: tx)
        }
        try RepoStore(database: database).insert(repo, in: tx)
        let config = ConfigStore(database: database)

        try insertItems(
            secrets: remote.secrets,
            variables: remote.variables,
            scope: .repository,
            repo: repo,
            keys: keys,
            in: tx
        )
        for (index, environment) in remote.environments.enumerated() {
            let id = EnvironmentID()
            let model = Self.environmentModel(environment, id: id, repositoryID: repo.id, sortOrder: index, now: now)
            try config.insertEnvironment(model, in: tx)
            try insertItems(
                secrets: environment.secrets,
                variables: environment.variables,
                scope: .environment(id),
                repo: repo,
                keys: keys,
                in: tx
            )
        }
    }

    static func environmentModel(
        _ environment: RemoteEnvironmentConfigModel,
        id: EnvironmentID,
        repositoryID: RepoID,
        sortOrder: Int,
        now: Date
    ) -> EnvironmentModel {
        let kind = environment.listing.branchPolicyKind
        let policy: DeploymentBranchPolicyModel = switch kind {
        case .all: .all
        case .protected: .protectedBranches
        case .custom: .custom(environment.patterns.map {
            BranchPatternModel(environmentID: id, pattern: $0.name, type: $0.type, githubPolicyID: $0.id)
        })
        }
        return EnvironmentModel(
            id: id,
            repositoryID: repositoryID,
            name: environment.name,
            syncedName: environment.name,
            branchPolicy: policy,
            syncedBranchPolicy: kind,
            foreignRulesJSON: environment.listing.foreignRulesJSON,
            githubEnvID: environment.listing.id,
            remoteUpdatedAt: environment.listing.updatedAt,
            sortOrder: sortOrder,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Inserts the listed items of one scope with the row shape every listed item shares
    /// (``SyncRowWriter/insertListedItem(repositoryID:scope:kind:name:remoteUpdatedAt:listedValue:isTombstone:keys:)``).
    private func insertItems(
        secrets: [GHSecretDTO],
        variables: [GHVariableListingModel],
        scope: ConfigScope,
        repo: RepoModel,
        keys: borrowing UnlockedKeys,
        in tx: StoreTransaction
    ) throws {
        let writer = SyncRowWriter(database: database, tx: tx, now: now)
        for secret in secrets {
            try writer.insertListedItem(
                repositoryID: repo.id,
                scope: scope,
                kind: .secret,
                name: secret.name,
                remoteUpdatedAt: secret.updatedAt,
                listedValue: nil,
                isTombstone: false,
                keys: keys
            )
        }
        for variable in variables {
            try writer.insertListedItem(
                repositoryID: repo.id,
                scope: scope,
                kind: .variable,
                name: variable.name,
                remoteUpdatedAt: variable.updatedAt,
                listedValue: variable.value,
                isTombstone: false,
                keys: keys
            )
        }
    }
}
