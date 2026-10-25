import Foundation
import GRDB
import VaultCore

/// Everything Sync's From Files review needs about held rows (v0.9.0, `share_hold`), without
/// ciphertext: the held rows of both item tables, the import records of their share files, and
/// the context to name and plan them.
public struct HeldShareInputsModel: Sendable, Hashable {
    /// The import record of every package id some row is held under (a package whose record
    /// is missing is still listed by its rows).
    public var packages: [ImportedSharePackageRecord]
    /// The pending-change inputs of every repository with a held `config_items` row or a
    /// destination with a held row, in sidebar order. Every item of those repositories is
    /// included (held or not), so the environment rules of a hold can be applied.
    public var repositories: [RepoPendingInputsModel]
    /// The held `destination_items` rows, by destination and name.
    public var destinationItems: [DestinationItemState]
    /// The destinations those rows belong to.
    public var destinations: [DestinationModel]

    public init(
        packages: [ImportedSharePackageRecord] = [],
        repositories: [RepoPendingInputsModel] = [],
        destinationItems: [DestinationItemState] = [],
        destinations: [DestinationModel] = []
    ) {
        self.packages = packages
        self.repositories = repositories
        self.destinationItems = destinationItems
        self.destinations = destinations
    }

    /// True when no row is held.
    public var isEmpty: Bool {
        destinationItems.isEmpty && !repositories.contains { $0.items.contains { $0.shareHold != nil } }
    }
}

/// Holds across `config_items` and `destination_items` (v0.9.0): the inputs of the From Files
/// review and releasing holds. Setting a hold belongs to the share importer
/// (``ConfigStore/setShareHold(_:itemIDs:in:)``, ``DestinationStore/setShareHold(_:itemIDs:in:)``).
public struct ShareHoldStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    public func fetchInputs() throws -> HeldShareInputsModel {
        try database.read { tx in try Self.inputs(db: tx.db) }
    }

    /// ``fetchInputs()`` now and after every change to the rows it reads.
    public func observeInputs() -> AsyncThrowingStream<HeldShareInputsModel, any Error> {
        database.observe { db in
            try Self.inputs(db: db)
        }
    }

    /// Releases every row of both tables held under one of `packageIDs`. Returns how many rows
    /// it released.
    @discardableResult
    public func clearShareHold(packageIDs: Set<SharePackageID>, in tx: StoreTransaction) throws -> Int {
        var released = 0
        for packageID in packageIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            released += try ConfigStore(database: database).clearShareHold(packageID: packageID, in: tx)
            released += try DestinationStore(database: database).clearShareHold(packageID: packageID, in: tx)
        }
        return released
    }

    /// Releases `itemIDs` in whichever table holds them (item ids never repeat across the
    /// tables). Returns how many rows it released.
    @discardableResult
    public func clearShareHold(itemIDs: [ConfigItemID], in tx: StoreTransaction) throws -> Int {
        guard !itemIDs.isEmpty else { return 0 }
        let keys = itemIDs.map(\.uuidString)
        let config = try ConfigItemRecord
            .filter(keys: keys)
            .filter(ConfigItemRecord.CodingKeys.shareHold != nil)
            .updateAll(tx.db, ConfigItemRecord.CodingKeys.shareHold.set(to: nil))
        let destination = try DestinationItemRecord
            .filter(keys: keys)
            .filter(DestinationItemRecord.CodingKeys.shareHold != nil)
            .updateAll(tx.db, DestinationItemRecord.CodingKeys.shareHold.set(to: nil))
        return config + destination
    }

    static func inputs(db: Database) throws -> HeldShareInputsModel {
        let heldConfigRepositories = try String.fetchSet(db, sql: """
            SELECT DISTINCT repository_id FROM config_items WHERE share_hold IS NOT NULL
            """)
        let destinationItems = try DestinationItemState.fetchAll(db, SQLRequest(literal: """
            SELECT \(sql: DestinationItemState.selection) FROM destination_items
            WHERE share_hold IS NOT NULL ORDER BY destination_id, name
            """))
        let destinationIDs = Set(destinationItems.map(\.destinationID.uuidString))
        let destinationRecords = try DestinationRecord.fetchAll(db, keys: Array(destinationIDs).sorted())
        // A share import only places destinations under repositories, so a Key Vault of its own holds nothing.
        let heldDestinationRepositories = Set(destinationRecords.compactMap(\.repositoryID))
        let repositoryIDs = heldConfigRepositories.union(heldDestinationRepositories.map(\.uuidString))
        guard !repositoryIDs.isEmpty else { return HeldShareInputsModel() }

        let repositories = try ConfigStore.allPendingInputs(db: db)
            .filter { repositoryIDs.contains($0.repository.id.uuidString) }
        var destinations: [DestinationModel] = []
        for repositoryID in heldDestinationRepositories.sorted(by: { $0.uuidString < $1.uuidString }) {
            destinations += try DestinationStore.destinationModels(repositoryID: repositoryID, db: db)
                .filter { destinationIDs.contains($0.id.uuidString) }
        }
        let packageIDs = Set(
            repositories.flatMap { $0.items.compactMap(\.shareHold?.uuidString) }
                + destinationItems.compactMap(\.shareHold?.uuidString)
        )
        let packages = try ImportedSharePackageRecord
            .fetchAll(db, keys: Array(packageIDs).sorted())
            .sorted { ($0.importedAt, $0.packageID.uuidString) > ($1.importedAt, $1.packageID.uuidString) }
        return HeldShareInputsModel(
            packages: packages,
            repositories: repositories,
            destinationItems: destinationItems,
            destinations: destinations
        )
    }
}
