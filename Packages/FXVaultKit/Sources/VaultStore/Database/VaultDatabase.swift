import Foundation
import GRDB

/// The migrated vault database: a `DatabasePool` on disk, or a `DatabaseQueue` in memory for
/// tests and previews (§4.3 Database). Create it with ``DatabaseFactory``.
///
/// GRDB stays inside VaultStore: callers work through the stores, and compose multi-table
/// transactions with ``write(_:)`` and the stores' `in:` overloads, which take a
/// ``StoreTransaction``.
///
/// ``write(_:)`` is **synchronous** on purpose. Sync bookkeeping (§4.3) records each outcome
/// right after gh returns; an async write could be cancelled and rolled back with the task, and
/// the item would be pushed again. There is no async write API.
public final class VaultDatabase: Sendable {
    /// The GRDB connection. Internal: only VaultStore (and its tests) touch GRDB.
    let writer: any DatabaseWriter

    /// The `vault.sqlite` URL, or nil for an in-memory database.
    public let fileURL: URL?

    init(writer: any DatabaseWriter, fileURL: URL?) {
        self.writer = writer
        self.fileURL = fileURL
    }

    /// True for an in-memory database (tests and previews).
    public var isInMemory: Bool {
        fileURL == nil
    }

    // MARK: - Transactions

    /// Runs `body` in one write transaction and commits it before returning. Blocks the calling
    /// thread until the writer is free.
    ///
    /// An error thrown by `body` rolls the transaction back and is rethrown unchanged; database
    /// failures are rethrown as ``StoreError``.
    ///
    /// Inside `body`, use only the stores' `in:` overloads. Calling a convenience method (one
    /// without `in:`), ``read(_:)``, ``write(_:)`` or ``checkpointTruncate()`` from inside the
    /// body traps: GRDB database access is not reentrant.
    public func write<T>(_ body: (StoreTransaction) throws -> T) throws -> T {
        try Self.translatingErrors {
            try writer.write { db in
                try body(StoreTransaction(db: db))
            }
        }
    }

    /// Runs `body` with a read-only view of the latest committed state. Writes inside `body` fail.
    public func read<T>(_ body: (StoreTransaction) throws -> T) throws -> T {
        try Self.translatingErrors {
            try writer.read { db in
                try body(StoreTransaction(db: db))
            }
        }
    }

    /// `PRAGMA wal_checkpoint(TRUNCATE)`: copies the WAL into `vault.sqlite` and truncates the
    /// `-wal` file to zero bytes, so superseded key material does not linger in it (D10).
    ///
    /// Call it after every key write (`vaults`, `key_wraps`) and on lock. It must run outside a
    /// transaction, so never call it from inside ``write(_:)``. A no-op for in-memory databases.
    public func checkpointTruncate() throws {
        guard !isInMemory else { return }
        try Self.translatingErrors {
            try writer.writeWithoutTransaction { db in
                _ = try db.checkpoint(.truncate)
            }
        }
    }

    /// Closes every connection. Further use throws. Only needed before deleting the files.
    public func close() throws {
        try Self.translatingErrors {
            if let pool = writer as? DatabasePool {
                try pool.close()
            } else if let queue = writer as? DatabaseQueue {
                try queue.close()
            }
        }
    }

    // MARK: - Observation

    /// A stream of `fetch` results: the current value first, then a new value after each
    /// committed change to the tables `fetch` reads (GRDB `ValueObservation`). Consecutive
    /// equal values are skipped. The stream ends with a ``StoreError`` if a fetch fails, and
    /// stops observing when the consumer stops iterating.
    func observe<T: Sendable & Equatable>(
        _ fetch: @escaping @Sendable (Database) throws -> T
    ) -> AsyncThrowingStream<T, any Error> {
        let observation = ValueObservation.tracking(fetch).removeDuplicates()
        let writer = writer
        return AsyncThrowingStream { continuation in
            let cancellable = observation.start(
                in: writer,
                scheduling: .task,
                onError: { error in
                    continuation.finish(throwing: Self.translate(error))
                },
                onChange: { value in
                    continuation.yield(value)
                }
            )
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

    // MARK: - Error translation

    /// Runs `body`, translating GRDB and decoding failures into ``StoreError``. Other errors
    /// (thrown by a caller's transaction body) pass through unchanged.
    static func translatingErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw translate(error)
        }
    }

    /// Maps one error. Never copies SQLite's message, which can quote names.
    static func translate(_ error: any Error) -> any Error {
        switch error {
        case let error as DatabaseError:
            return storeError(for: error)
        case is RowDecodingError, is DecodingError:
            return StoreError.invalidStoredValue
        default:
            return error
        }
    }

    private static func storeError(for error: DatabaseError) -> StoreError {
        switch error.extendedResultCode {
        case .SQLITE_CONSTRAINT_UNIQUE:
            return .constraintViolation(.unique)
        case .SQLITE_CONSTRAINT_PRIMARYKEY:
            return .constraintViolation(.primaryKey)
        case .SQLITE_CONSTRAINT_CHECK:
            return .constraintViolation(.check)
        case .SQLITE_CONSTRAINT_FOREIGNKEY:
            return .constraintViolation(.foreignKey)
        case .SQLITE_CONSTRAINT_NOTNULL:
            return .constraintViolation(.notNull)
        default:
            break
        }
        switch error.resultCode {
        case .SQLITE_CONSTRAINT:
            return .constraintViolation(.other)
        case .SQLITE_BUSY, .SQLITE_LOCKED:
            return .busy
        case .SQLITE_CORRUPT, .SQLITE_NOTADB:
            return .corruptDatabase
        default:
            return .database(code: error.extendedResultCode.rawValue)
        }
    }
}

/// One open transaction (or read) on the vault database, passed to ``VaultDatabase/write(_:)``
/// and ``VaultDatabase/read(_:)`` bodies and on to the stores' `in:` overloads.
///
/// Not `Sendable` and only valid inside the body that received it: never store it or let it
/// escape.
public struct StoreTransaction {
    let db: Database
}
