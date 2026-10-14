import Foundation
import GRDB
import VaultCore

/// The `repositories` table (§6 `v2_accounts_repos`, `v5_create_policies`).
///
/// `owner_login`/`name` are unique without regard to case, and `github_id` is unique.
/// Deleting a repository cascades to its environments, items and branch patterns, and sets
/// its journal rows' `repository_id` to NULL.
public struct RepoStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    // MARK: - Reads

    /// Every repository, ordered by owner then name (case-insensitive).
    public func fetchAll() throws -> [RepoModel] {
        try database.read { try fetchAll(in: $0) }
    }

    public func fetchAll(in tx: StoreTransaction) throws -> [RepoModel] {
        try Self.orderedRequest.fetchAll(tx.db).map(\.model)
    }

    /// The repositories accessed through one account.
    public func fetchAll(accountLogin: String) throws -> [RepoModel] {
        try database.read { tx in
            try Self.orderedRequest
                .filter(RepositoryRecord.CodingKeys.accountLogin.collating(.nocase) == accountLogin)
                .fetchAll(tx.db)
                .map(\.model)
        }
    }

    public func fetch(id: RepoID) throws -> RepoModel? {
        try database.read { try fetch(id: id, in: $0) }
    }

    public func fetch(id: RepoID, in tx: StoreTransaction) throws -> RepoModel? {
        try RepositoryRecord.fetchOne(tx.db, key: id.uuidString)?.model
    }

    /// The repository `owner/name`, matched without regard to case.
    public func fetch(ownerLogin: String, name: String) throws -> RepoModel? {
        try database.read { try fetch(ownerLogin: ownerLogin, name: name, in: $0) }
    }

    public func fetch(ownerLogin: String, name: String, in tx: StoreTransaction) throws -> RepoModel? {
        try RepositoryRecord
            .filter(RepositoryRecord.CodingKeys.ownerLogin.collating(.nocase) == ownerLogin)
            .filter(RepositoryRecord.CodingKeys.name.collating(.nocase) == name)
            .fetchOne(tx.db)?
            .model
    }

    /// The repository with GitHub node id `githubID`.
    public func fetch(githubID: String) throws -> RepoModel? {
        try database.read { tx in
            try RepositoryRecord
                .filter(RepositoryRecord.CodingKeys.githubID == githubID)
                .fetchOne(tx.db)?
                .model
        }
    }

    // MARK: - Writes

    /// Inserts a new repository. The account must exist (foreign key). Throws
    /// ``StoreError/constraintViolation(_:)`` (`.unique`) for a duplicate `owner/name` or
    /// `githubID`.
    public func insert(_ repo: RepoModel) throws {
        try database.write { try insert(repo, in: $0) }
    }

    public func insert(_ repo: RepoModel, in tx: StoreTransaction) throws {
        try RepositoryRecord(repo).insert(tx.db)
    }

    /// Replaces every column of the existing row. Throws ``StoreError/notFound`` if there is none.
    public func update(_ repo: RepoModel) throws {
        try database.write { try update(repo, in: $0) }
    }

    public func update(_ repo: RepoModel, in tx: StoreTransaction) throws {
        do {
            try RepositoryRecord(repo).update(tx.db)
        } catch is RecordError {
            throw StoreError.notFound
        }
    }

    /// Deletes the repository and, by cascade, its environments, items and patterns. Returns
    /// false if there was none.
    @discardableResult
    public func delete(id: RepoID) throws -> Bool {
        try database.write { try delete(id: id, in: $0) }
    }

    @discardableResult
    public func delete(id: RepoID, in tx: StoreTransaction) throws -> Bool {
        try RepositoryRecord.deleteOne(tx.db, key: id.uuidString)
    }

    // MARK: - Observation

    /// Every repository (sidebar), now and after each change.
    public func observeAll() -> AsyncThrowingStream<[RepoModel], any Error> {
        database.observe { db in
            try Self.orderedRequest.fetchAll(db).map(\.model)
        }
    }

    /// One repository, now and after each change; nil once it is deleted.
    public func observe(id: RepoID) -> AsyncThrowingStream<RepoModel?, any Error> {
        let key = id.uuidString
        return database.observe { db in
            try RepositoryRecord.fetchOne(db, key: key)?.model
        }
    }

    static var orderedRequest: QueryInterfaceRequest<RepositoryRecord> {
        RepositoryRecord.order(
            RepositoryRecord.CodingKeys.ownerLogin.collating(.nocase),
            RepositoryRecord.CodingKeys.name.collating(.nocase)
        )
    }
}
