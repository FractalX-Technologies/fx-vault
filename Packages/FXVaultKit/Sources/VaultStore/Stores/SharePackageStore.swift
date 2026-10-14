import Foundation
import GRDB
import VaultCore

/// `imported_share_packages` (§6 `v6_sharing`): which share packages were already imported, for
/// the replay warning (§9.5).
public struct SharePackageStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    /// True if a package with this id was imported before.
    public func hasImported(_ packageID: SharePackageID) throws -> Bool {
        try fetch(packageID) != nil
    }

    public func fetch(_ packageID: SharePackageID) throws -> ImportedSharePackageRecord? {
        try database.read { tx in
            try ImportedSharePackageRecord.fetchOne(tx.db, key: packageID.uuidString)
        }
    }

    /// Every imported package, most recent import first.
    public func fetchAll() throws -> [ImportedSharePackageRecord] {
        try database.read { tx in
            try ImportedSharePackageRecord
                .order(ImportedSharePackageRecord.CodingKeys.importedAt.desc)
                .fetchAll(tx.db)
        }
    }

    /// Records an import. A package imported again after the user confirmed the replay warning
    /// keeps one row, updated to the latest import.
    public func recordImport(_ package: ImportedSharePackageRecord) throws {
        try database.write { try recordImport(package, in: $0) }
    }

    /// Use inside the share importer's single transaction (§9.5).
    public func recordImport(_ package: ImportedSharePackageRecord, in tx: StoreTransaction) throws {
        try package.upsert(tx.db)
    }
}
