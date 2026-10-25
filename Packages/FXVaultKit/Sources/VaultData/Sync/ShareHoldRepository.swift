import Foundation
import SyncEngine
import VaultCore
import VaultStore

/// Rows held by share files (v0.9.0, tasks/todo.md P8): the From Files review data and releasing
/// holds outside Sync.
///
/// The share importer holds every imported row the remote does not have (`share_hold` = the
/// package id). A held row never enters a Sync plan (``SyncRepository``,
/// ``DestinationSyncRepository``) until the user includes its file in a Sync, releases it here,
/// or uses Push on Next Sync on it (``releaseHold(itemIDs:)``). Deleting or reverting a held row
/// is the user's own change and is never held.
public struct ShareHoldRepository: Sendable {
    private let session: VaultSession

    public init(session: VaultSession) {
        self.session = session
    }

    private var store: ShareHoldStore {
        ShareHoldStore(database: session.database)
    }

    /// Every share file with held rows, most recent import first. Needs no keys.
    public func heldShares() throws(SyncRepositoryError) -> [HeldShareModel] {
        let inputs = try performSync { try store.fetchInputs() }
        return Self.heldShares(inputs)
    }

    /// ``heldShares()`` now and after every change to the rows it reads.
    public func observeHeldShares() -> AsyncThrowingStream<[HeldShareModel], any Error> {
        ObservationMapper.map(store.observeInputs()) { inputs in
            Self.heldShares(inputs)
        }
    }

    /// Releases every row held under `packageID`, in both item tables: the next Sync plans them
    /// as ordinary pending changes. Returns how many rows it released.
    ///
    /// - Throws: `.vault(.locked)`, `.store(_)`.
    @discardableResult
    public func releaseHold(packageID: SharePackageID) throws(SyncRepositoryError) -> Int {
        try performSync {
            try session.write { _, tx in try store.clearShareHold(packageIDs: [packageID], in: tx) }
        }
    }

    /// Releases `itemIDs` only (Push on Next Sync on a held row). Returns how many rows it
    /// released.
    ///
    /// - Throws: `.vault(.locked)`, `.store(_)`.
    @discardableResult
    public func releaseHold(itemIDs: [ConfigItemID]) throws(SyncRepositoryError) -> Int {
        guard !itemIDs.isEmpty else { return 0 }
        return try performSync {
            try session.write { _, tx in try store.clearShareHold(itemIDs: itemIDs, in: tx) }
        }
    }

    // MARK: - Building the review data

    static func heldShares(_ inputs: HeldShareInputsModel) -> [HeldShareModel] {
        guard !inputs.isEmpty else { return [] }
        var builders: [SharePackageID: Builder] = [:]

        for repository in inputs.repositories {
            let snapshot = RepoSnapshotMapper.snapshot(repository)
            let filter = HeldChangeFilter(snapshot: snapshot, holds: SyncHolds.holds(of: repository))
            let environments = Dictionary(repository.environments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (state, item) in zip(repository.items, snapshot.items) {
                guard let packageID = state.shareHold, Self.isPending(item) else { continue }
                let environment = item.scope.environmentID.flatMap { environments[$0] }
                let held = HeldShareItemModel(id: item.id, kind: item.kind, name: item.name, isNew: !item.isSynced)
                builders[packageID, default: Builder()].addScopeItem(
                    held,
                    repository: repository.repository,
                    scope: item.scope,
                    environment: environment,
                    holdsEnvironment: item.scope.environmentID.flatMap { filter.heldEnvironments[$0]?.contains(packageID) } ?? false
                )
            }
        }

        let destinations = Dictionary(inputs.destinations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let repositories = Dictionary(inputs.repositories.map { ($0.repository.id, $0.repository) }, uniquingKeysWith: { first, _ in first })
        for state in inputs.destinationItems {
            guard let packageID = state.shareHold,
                  let operation = state.pendingOperation, operation != .delete,
                  let destination = destinations[state.destinationID],
                  let repositoryID = destination.repositoryID,
                  let repository = repositories[repositoryID]
            else { continue }
            let held = HeldShareItemModel(id: state.id, kind: state.kind, name: state.name, isNew: operation == .add)
            builders[packageID, default: Builder()].addDestinationItem(held, repository: repository, destination: destination)
        }

        let records = Dictionary(inputs.packages.map { ($0.packageID, $0) }, uniquingKeysWith: { first, _ in first })
        let repositoryOrder = Dictionary(inputs.repositories.enumerated().map { ($0.element.repository.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let destinationOrder = Dictionary(inputs.destinations.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let models = builders.map { packageID, builder in
            let record = records[packageID]
            return HeldShareModel(
                packageID: packageID,
                senderName: record?.senderName,
                senderDeviceID: record?.senderDeviceID,
                createdAt: record?.createdAt,
                importedAt: record?.importedAt,
                repositories: builder.repositories(repositoryOrder: repositoryOrder, destinationOrder: destinationOrder)
            )
        }
        return models.sorted { lhs, rhs in
            switch (lhs.importedAt, rhs.importedAt) {
            case (let left?, let right?) where left != right: left > right
            case (.some, .none): true
            case (.none, .some): false
            default: lhs.packageID.uuidString < rhs.packageID.uuidString
            }
        }
    }

    /// A row Sync would write: not a tombstone (deleting a held row is never held), and new, renamed
    /// or carrying a new value. A held row the user reverted has nothing to send.
    static func isPending(_ item: ConfigItemSnapshotModel) -> Bool {
        !item.isDeleted && (!item.isSynced || item.isRenamed || item.isValueChanged || item.forcePush)
    }

    /// Collects one package's rows.
    private struct Builder {
        private struct ScopeKey: Hashable {
            let repositoryID: RepoID
            let scope: ConfigScope
        }

        private struct DestinationKey: Hashable {
            let repositoryID: RepoID
            let destinationID: DestinationID
        }

        private var repositoryModels: [RepoID: RepoModel] = [:]
        private var scopes: [ScopeKey: (environment: EnvironmentModel?, items: [HeldShareItemModel], holdsEnvironment: Bool)] = [:]
        private var destinations: [DestinationKey: (destination: DestinationModel, items: [HeldShareItemModel])] = [:]

        mutating func addScopeItem(
            _ item: HeldShareItemModel,
            repository: RepoModel,
            scope: ConfigScope,
            environment: EnvironmentModel?,
            holdsEnvironment: Bool
        ) {
            repositoryModels[repository.id] = repository
            let key = ScopeKey(repositoryID: repository.id, scope: scope)
            var entry = scopes[key] ?? (environment, [], false)
            entry.items.append(item)
            entry.holdsEnvironment = entry.holdsEnvironment || holdsEnvironment
            scopes[key] = entry
        }

        mutating func addDestinationItem(_ item: HeldShareItemModel, repository: RepoModel, destination: DestinationModel) {
            repositoryModels[repository.id] = repository
            let key = DestinationKey(repositoryID: repository.id, destinationID: destination.id)
            var entry = destinations[key] ?? (destination, [])
            entry.items.append(item)
            destinations[key] = entry
        }

        func repositories(repositoryOrder: [RepoID: Int], destinationOrder: [DestinationID: Int]) -> [HeldShareRepositoryModel] {
            repositoryModels.values
                .sorted { (repositoryOrder[$0.id] ?? .max, $0.id.uuidString) < (repositoryOrder[$1.id] ?? .max, $1.id.uuidString) }
                .map { repository in
                    let scopeModels = scopes
                        .filter { $0.key.repositoryID == repository.id }
                        .sorted { Self.order($0.key.scope, $0.value.environment) < Self.order($1.key.scope, $1.value.environment) }
                        .map { key, entry in
                            HeldShareScopeModel(
                                scope: key.scope,
                                environmentName: entry.environment?.name,
                                items: entry.items.sorted { ($0.name, $0.kind.rawValue) < ($1.name, $1.kind.rawValue) },
                                holdsEnvironment: entry.holdsEnvironment
                            )
                        }
                    let destinationModels = destinations
                        .filter { $0.key.repositoryID == repository.id }
                        .sorted { (destinationOrder[$0.key.destinationID] ?? .max) < (destinationOrder[$1.key.destinationID] ?? .max) }
                        .map { _, entry in
                            HeldShareDestinationModel(
                                destination: entry.destination,
                                items: entry.items.sorted { ($0.name, $0.kind.rawValue) < ($1.name, $1.kind.rawValue) }
                            )
                        }
                    return HeldShareRepositoryModel(repository: repository, scopes: scopeModels, destinations: destinationModels)
                }
        }

        /// Repository level first, then environments by their sidebar order and name.
        private static func order(_ scope: ConfigScope, _ environment: EnvironmentModel?) -> (Int, Int, String) {
            guard scope.environmentID != nil else { return (0, 0, "") }
            return (1, environment?.sortOrder ?? .max, environment?.nameKey ?? scope.environmentID?.uuidString ?? "")
        }
    }
}

/// The holds of one repository's rows, as ``HeldChangeFilter`` takes them.
enum SyncHolds {
    static func holds(of inputs: RepoPendingInputsModel) -> [ConfigItemID: SharePackageID] {
        var holds: [ConfigItemID: SharePackageID] = [:]
        for item in inputs.items {
            if let packageID = item.shareHold { holds[item.id] = packageID }
        }
        return holds
    }
}

// MARK: - Testing

@_spi(Testing)
extension ShareHoldRepository {
    /// Holds `itemIDs` (configuration or destination rows) under `packageID` and records the
    /// import, as the share importer does. For the app's tests, which reach the database only
    /// through VaultData (scripts/lint.sh).
    ///
    /// - Throws: `.vault(.locked)`, `.store(_)`.
    public func hold(
        _ itemIDs: [ConfigItemID],
        under packageID: SharePackageID,
        senderName: String?,
        senderDeviceID: String? = nil,
        importedAt: Date
    ) throws(SyncRepositoryError) {
        let database = session.database
        try performSync {
            try session.write { _, tx in
                try ConfigStore(database: database).setShareHold(packageID, itemIDs: itemIDs, in: tx)
                try DestinationStore(database: database).setShareHold(packageID, itemIDs: itemIDs, in: tx)
                try SharePackageStore(database: database).recordImport(ImportedSharePackageRecord(
                    packageID: packageID,
                    createdAt: importedAt,
                    importedAt: importedAt,
                    senderName: senderName,
                    senderDeviceID: senderDeviceID
                ), in: tx)
            }
        }
    }
}
