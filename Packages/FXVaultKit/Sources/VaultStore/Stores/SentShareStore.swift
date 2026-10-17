import Foundation
import GRDB
import VaultCore

/// `sent_shares` (§6 `v14_project_shares`, v0.9.0): the share files this Mac wrote, for
/// Settings › Sharing. Names only; nothing here is sealed.
public struct SentShareStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    /// Records an export. Use inside the exporter's transaction when there is one.
    public func insert(_ share: SentShareModel, in tx: StoreTransaction) throws {
        try SentShareRecord(share).insert(tx.db)
    }

    public func insert(_ share: SentShareModel) throws {
        try database.write { try insert(share, in: $0) }
    }

    /// Every sent file, newest first.
    public func fetchAll() throws -> [SentShareModel] {
        try database.read { tx in try Self.request.fetchAll(tx.db).map(\.model) }
    }

    public func fetch(id: SentShareID) throws -> SentShareModel? {
        try database.read { tx in try SentShareRecord.fetchOne(tx.db, key: id.uuidString)?.model }
    }

    /// Every sent file, newest first, now and after each change.
    public func observe() -> AsyncThrowingStream<[SentShareModel], any Error> {
        database.observe { db in
            try Self.request.fetchAll(db).map(\.model)
        }
    }

    /// Removes one entry from the log. Returns false when there was none.
    @discardableResult
    public func delete(id: SentShareID) throws -> Bool {
        try database.write { tx in try SentShareRecord.deleteOne(tx.db, key: id.uuidString) }
    }

    private static var request: QueryInterfaceRequest<SentShareRecord> {
        SentShareRecord.order(SentShareRecord.CodingKeys.createdAt.desc, SentShareRecord.CodingKeys.id)
    }
}
