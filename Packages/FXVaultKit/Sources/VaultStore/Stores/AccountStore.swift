import Foundation
import GRDB
import VaultCore

/// The `accounts` table (§6 `v2_accounts_repos`). Logins compare without regard to case.
public struct AccountStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    /// Every account, ordered by login (case-insensitive).
    public func fetchAll() throws -> [AccountModel] {
        try database.read { try fetchAll(in: $0) }
    }

    public func fetchAll(in tx: StoreTransaction) throws -> [AccountModel] {
        try Self.orderedRequest.fetchAll(tx.db).map(\.model)
    }

    /// The account with `login` in any case, or nil.
    public func fetch(login: String) throws -> AccountModel? {
        try database.read { try fetch(login: login, in: $0) }
    }

    public func fetch(login: String, in tx: StoreTransaction) throws -> AccountModel? {
        try AccountRecord.fetchOne(tx.db, key: login)?.model
    }

    /// Inserts the account, or updates the other columns of the existing row with the same login
    /// in any case (the stored login keeps its original case).
    public func save(_ account: AccountModel) throws {
        try database.write { try save(account, in: $0) }
    }

    public func save(_ account: AccountModel, in tx: StoreTransaction) throws {
        try AccountRecord(account).upsert(tx.db)
    }

    /// Marks every account whose login is not in `presentLogins` as absent (gh no longer lists
    /// it) and every listed one as present with `lastSeenAt = now`. Rows are kept for their
    /// repositories.
    public func updatePresence(presentLogins: Set<String>, now: Date) throws {
        try database.write { try updatePresence(presentLogins: presentLogins, now: now, in: $0) }
    }

    public func updatePresence(presentLogins: Set<String>, now: Date, in tx: StoreTransaction) throws {
        let folded = Set(presentLogins.map(OwnerLoginValidator.foldKey))
        for var record in try AccountRecord.fetchAll(tx.db) {
            let isPresent = folded.contains(OwnerLoginValidator.foldKey(record.login))
            guard record.isPresent != isPresent || isPresent else { continue }
            record.isPresent = isPresent
            if isPresent {
                record.lastSeenAt = now
            }
            try record.update(tx.db)
        }
    }

    /// Deletes the account. Throws ``StoreError/constraintViolation(_:)`` (`.foreignKey`) while
    /// repositories still use it. Returns false if there was none.
    @discardableResult
    public func delete(login: String) throws -> Bool {
        try database.write { try delete(login: login, in: $0) }
    }

    @discardableResult
    public func delete(login: String, in tx: StoreTransaction) throws -> Bool {
        try AccountRecord.deleteOne(tx.db, key: login)
    }

    /// Every account, now and after each change.
    public func observeAll() -> AsyncThrowingStream<[AccountModel], any Error> {
        database.observe { db in
            try Self.orderedRequest.fetchAll(db).map(\.model)
        }
    }

    private static var orderedRequest: QueryInterfaceRequest<AccountRecord> {
        AccountRecord.order(AccountRecord.CodingKeys.login.collating(.nocase))
    }
}
