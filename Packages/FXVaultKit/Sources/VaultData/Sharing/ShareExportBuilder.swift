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
/// verified. An environment carries its branch policy only when the selection names the
/// environment itself; one reached through some of its items is a partial environment (no
/// policy, schema v2). The package is written with the lowest schema version that holds it. A
/// folder (v0.7.0) becomes a folder package (schema v3) with every item and its value.
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
        let package = if case .folder(let folderID) = selection {
            try folderPackage(folderID, senderName: senderName, appVersion: appVersion, includeValues: includeValues)
        } else {
            try repositoryPackage(selection, senderName: senderName, appVersion: appVersion, includeValues: includeValues)
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

    /// A folder's items, each with its value when asked for (a folder item always has one).
    private func folderPackage(
        _ folderID: FolderID,
        senderName: String,
        appVersion: String,
        includeValues: Bool
    ) throws(SharingError) -> SharePackageModel {
        let database = session.database
        let createdAt = clock.now
        return try performSharing {
            try session.read { keys, tx in
                let store = FolderStore(database: database)
                guard let folder = try store.fetchFolder(id: folderID, in: tx) else {
                    throw SharingError.config(.folderNotFound)
                }
                let records = try store.fetchItemRecords(folderID: folderID, in: tx)
                let keys = copy keys
                func items(_ kind: ConfigKind) throws -> [ShareItemModel] {
                    try records.filter { $0.kind == kind }.map { record in
                        ShareItemModel(
                            name: record.name,
                            value: includeValues ? try FolderFieldCipher.openValue(of: record, keys: keys) : nil,
                            valueState: .present,
                            githubUpdatedAt: nil,
                            syncState: .pending
                        )
                    }
                }
                return SharePackageModel.folder(
                    named: folder.name,
                    secrets: try items(.secret),
                    variables: try items(.variable),
                    createdAt: createdAt,
                    producer: ShareProducerModel(version: appVersion),
                    sender: ShareSenderModel(displayName: DisplayNameSanitizer.sanitize(senderName))
                )
            }
        }
    }

    /// The rows of a repository selection.
    private func repositoryPackage(
        _ selection: ShareSelectionModel,
        senderName: String,
        appVersion: String,
        includeValues: Bool
    ) throws(SharingError) -> SharePackageModel {
        let database = session.database
        let createdAt = clock.now
        return try performSharing {
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
                let environments = try rows.environments.map { selected in
                    let environment = selected.environment
                    let records = rows.items(in: .environment(environment.id))
                    return ShareEnvironmentModel(
                        name: environment.name,
                        deploymentBranchPolicy: selected.includesBranchPolicy
                            ? ShareBranchPolicyModel(environment.branchPolicy)
                            : nil,
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
    }

    /// The names and counts of a package (no values).
    static func preview(_ package: SharePackageModel) -> ShareExportPreviewModel {
        ShareExportPreviewModel(
            scope: package.scope,
            repositoryFullName: package.isFolder ? "" : package.repository.fullName,
            environmentNames: package.repository.environments.map(\.name),
            itemCount: package.itemCount,
            valueMissingNames: package.flattenedItems
                .filter { $0.item.valueState == .missing }
                .map(\.item.name),
            summary: package.contentSummary,
            folderName: package.folder?.name
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

/// An environment in a selection and whether the environment itself was selected (its branch
/// policy is shared) or only some of its items (a partial environment).
private struct SelectedEnvironment {
    let environment: EnvironmentModel
    let includesBranchPolicy: Bool
}

/// The rows a selection covers (live rows only).
private struct ShareSelectionRows {
    let scope: ShareScope
    let repository: RepoModel
    let environments: [SelectedEnvironment]
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
            var environments: [SelectedEnvironment] = []
            if let environmentID = record.environmentID {
                guard let environment = try config.fetchEnvironment(id: environmentID, in: tx), !environment.isDeleted else {
                    throw SharingError.environmentNotFound
                }
                environments = [SelectedEnvironment(environment: environment, includesBranchPolicy: false)]
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
                environments: [SelectedEnvironment(environment: environment, includesBranchPolicy: true)],
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
                environments: environments.map { SelectedEnvironment(environment: $0, includesBranchPolicy: true) },
                itemsByScope: Dictionary(grouping: records.filter { liveScopes.contains($0.scope) }, by: \.scope)
            )
        case .subset(let subset):
            return try loadSubset(subset, config: config, repositories: repositories, tx: tx)
        case .folder:
            // Folders are built by ``ShareExportBuilder/folderPackage(_:senderName:appVersion:includeValues:)``.
            throw SharingError.unexpected
        }
    }

    /// Whole environments with every live item, plus the individual items; an item's environment
    /// that is not selected itself becomes a partial environment. Every id must be live and in
    /// the subset's repository.
    private static func loadSubset(
        _ subset: ShareSubsetModel,
        config: ConfigStore,
        repositories: RepoStore,
        tx: StoreTransaction
    ) throws -> ShareSelectionRows {
        let repository = try fetchRepository(subset.repositoryID, repositories: repositories, tx: tx)
        let live = try config.fetchEnvironments(repositoryID: repository.id, in: tx).filter { !$0.isDeleted }
        let liveIDs = Set(live.map(\.id))
        guard subset.environmentIDs.isSubset(of: liveIDs) else { throw SharingError.environmentNotFound }
        let records = try config.fetchItemRecords(repositoryID: repository.id, in: tx).filter { !$0.isDeleted }
        let recordsByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var selected: [ConfigItemRecord] = []
        for itemID in subset.itemIDs {
            guard let record = recordsByID[itemID] else { throw SharingError.itemNotFound }
            if let environmentID = record.environmentID {
                guard liveIDs.contains(environmentID) else { throw SharingError.environmentNotFound }
                if subset.environmentIDs.contains(environmentID) { continue }
            }
            selected.append(record)
        }
        selected += records.filter { record in
            record.environmentID.map(subset.environmentIDs.contains) ?? false
        }
        let partialIDs = Set(selected.compactMap(\.environmentID)).subtracting(subset.environmentIDs)
        let environments = live.compactMap { environment -> SelectedEnvironment? in
            if subset.environmentIDs.contains(environment.id) {
                return SelectedEnvironment(environment: environment, includesBranchPolicy: true)
            }
            return partialIDs.contains(environment.id)
                ? SelectedEnvironment(environment: environment, includesBranchPolicy: false)
                : nil
        }
        let selectedIDs = Set(selected.map(\.id))
        let ordered = records.filter { selectedIDs.contains($0.id) }
        return ShareSelectionRows(
            scope: scope(
                itemCount: ordered.count,
                repositoryItemCount: ordered.filter { $0.environmentID == nil }.count,
                environments: environments
            ),
            repository: repository,
            environments: environments,
            itemsByScope: Dictionary(grouping: ordered, by: \.scope)
        )
    }

    /// The narrowest §9.3 scope that describes the contents.
    private static func scope(itemCount: Int, repositoryItemCount: Int, environments: [SelectedEnvironment]) -> ShareScope {
        let wholeCount = environments.filter(\.includesBranchPolicy).count
        if wholeCount == 0, itemCount == 1 { return .secret }
        if wholeCount == 1, environments.count == 1, repositoryItemCount == 0 { return .environment }
        return .repository
    }

    private static func fetchRepository(_ id: RepoID, repositories: RepoStore, tx: StoreTransaction) throws -> RepoModel {
        guard let repository = try repositories.fetch(id: id, in: tx) else { throw SharingError.repositoryNotFound }
        return repository
    }
}
