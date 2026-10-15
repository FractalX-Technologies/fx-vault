import Foundation
import SharingKit
import VaultCore
import VaultCrypto
import VaultStore

/// Builds the share package of a selection (§9.3) from the vault rows.
///
/// Values are decrypted inside `VaultSession.read` (rotation-safe) only when asked for; the
/// manifest form carries `valueState` without values. Deleted items and environments pending
/// deletion are left out. A value-missing secret travels by name only (§7.8). An item counts as
/// `synced` for the receiver only when nothing is pending locally and its last push was
/// verified.
struct ShareExportBuilder: Sendable {
    let session: VaultSession
    let clock: any VaultClock

    /// The package of `selection`. With `includeValues` the caller wipes it
    /// (`SharePackageModel.wipeValues()`).
    ///
    /// - Throws: `.repositoryNotFound`, `.environmentNotFound`, `.itemNotFound`,
    ///   `.nothingToShare`, `.share(.invalidPackage)` (a name the share format refuses),
    ///   `.vault(.locked)`.
    func build(
        _ selection: ShareSelectionModel,
        senderName: String,
        appVersion: String,
        includeValues: Bool
    ) throws(SharingError) -> SharePackageModel {
        let database = session.database
        let createdAt = clock.now
        let package = try performSharing {
            try session.read { keys, tx in
                let rows = try ShareSelectionRows.load(selection, database: database, tx: tx)
                let keys = copy keys
                func item(_ record: ConfigItemRecord) throws -> ShareItemModel {
                    let value = includeValues ? try ConfigFieldCipher.openValue(of: record, keys: keys) : nil
                    return ShareItemModel(
                        name: record.name,
                        value: value,
                        valueState: record.valueCiphertext == nil ? .missing : .present,
                        githubUpdatedAt: record.remoteUpdatedAt,
                        syncState: Self.syncState(record)
                    )
                }
                func items(_ records: [ConfigItemRecord], kind: ConfigKind) throws -> [ShareItemModel] {
                    try records.filter { $0.kind == kind }.map(item)
                }
                let environments = try rows.environments.map { environment in
                    let records = rows.items(in: .environment(environment.id))
                    return ShareEnvironmentModel(
                        name: environment.name,
                        deploymentBranchPolicy: ShareBranchPolicyModel(environment.branchPolicy),
                        secrets: try items(records, kind: .secret),
                        variables: try items(records, kind: .variable)
                    )
                }
                let repositoryItems = rows.items(in: .repository)
                return SharePackageModel(
                    createdAt: createdAt,
                    producer: ShareProducerModel(version: appVersion),
                    sender: ShareSenderModel(displayName: DisplayNameSanitizer.sanitize(senderName)),
                    scope: rows.scope,
                    repository: ShareRepositoryModel(
                        owner: rows.repository.ownerLogin,
                        name: rows.repository.name,
                        githubRepoID: rows.repository.githubID,
                        secrets: try items(repositoryItems, kind: .secret),
                        variables: try items(repositoryItems, kind: .variable),
                        environments: environments
                    )
                )
            }
        }
        guard package.itemCount > 0 || !package.repository.environments.isEmpty else {
            package.wipeValues()
            throw .nothingToShare
        }
        do {
            try SharePackageValidator.validate(package, mode: includeValues ? .payload : .manifest)
        } catch {
            package.wipeValues()
            throw .share(error)
        }
        return package
    }

    /// The names and counts of a package (no values).
    static func preview(_ package: SharePackageModel) -> ShareExportPreviewModel {
        ShareExportPreviewModel(
            scope: package.scope,
            repositoryFullName: package.repository.fullName,
            environmentNames: package.repository.environments.map(\.name),
            itemCount: package.itemCount,
            valueMissingNames: package.flattenedItems
                .filter { $0.item.valueState == .missing }
                .map(\.item.name)
        )
    }

    /// `synced` only when GitHub has exactly the local value: no pending change and a verified
    /// push (a value from an unverified share is not confirmed either).
    private static func syncState(_ record: ConfigItemRecord) -> ShareSyncState {
        let state = record.state
        let isConfirmed = state.model.syncStatus == .synced && state.verifyState == .verified
        return isConfirmed ? .synced : .pending
    }
}

/// The rows a selection covers (live rows only).
private struct ShareSelectionRows {
    let scope: ShareScope
    let repository: RepoModel
    let environments: [EnvironmentModel]
    let itemsByScope: [ConfigScope: [ConfigItemRecord]]

    func items(in scope: ConfigScope) -> [ConfigItemRecord] {
        itemsByScope[scope] ?? []
    }

    static func load(_ selection: ShareSelectionModel, database: VaultDatabase, tx: StoreTransaction) throws -> ShareSelectionRows {
        let config = ConfigStore(database: database)
        let repositories = RepoStore(database: database)
        switch selection {
        case .item(let itemID):
            guard let record = try config.fetchItemRecord(id: itemID, in: tx), !record.isDeleted else {
                throw SharingError.itemNotFound
            }
            let repository = try fetchRepository(record.repositoryID, repositories: repositories, tx: tx)
            var environments: [EnvironmentModel] = []
            if let environmentID = record.environmentID {
                guard let environment = try config.fetchEnvironment(id: environmentID, in: tx), !environment.isDeleted else {
                    throw SharingError.environmentNotFound
                }
                environments = [environment]
            }
            return ShareSelectionRows(scope: .secret, repository: repository, environments: environments, itemsByScope: [record.scope: [record]])
        case .environment(let environmentID):
            guard let environment = try config.fetchEnvironment(id: environmentID, in: tx), !environment.isDeleted else {
                throw SharingError.environmentNotFound
            }
            let repository = try fetchRepository(environment.repositoryID, repositories: repositories, tx: tx)
            let records = try config.fetchItemRecords(repositoryID: repository.id, scope: .environment(environmentID), in: tx)
            return ShareSelectionRows(
                scope: .environment,
                repository: repository,
                environments: [environment],
                itemsByScope: [.environment(environmentID): records.filter { !$0.isDeleted }]
            )
        case .repository(let repositoryID):
            let repository = try fetchRepository(repositoryID, repositories: repositories, tx: tx)
            let environments = try config.fetchEnvironments(repositoryID: repositoryID, in: tx).filter { !$0.isDeleted }
            let records = try config.fetchItemRecords(repositoryID: repositoryID, in: tx).filter { !$0.isDeleted }
            let liveScopes = Set([ConfigScope.repository] + environments.map { .environment($0.id) })
            return ShareSelectionRows(
                scope: .repository,
                repository: repository,
                environments: environments,
                itemsByScope: Dictionary(grouping: records.filter { liveScopes.contains($0.scope) }, by: \.scope)
            )
        }
    }

    private static func fetchRepository(_ id: RepoID, repositories: RepoStore, tx: StoreTransaction) throws -> RepoModel {
        guard let repository = try repositories.fetch(id: id, in: tx) else { throw SharingError.repositoryNotFound }
        return repository
    }
}
