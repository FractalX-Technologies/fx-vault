import Foundation
import GRDB
import VaultCore

/// The sync journal (§6 `v4_sync_journal`, D28): one row per gh command of a sync run.
///
/// Protocol: ``appendInFlight(_:)`` right before a GitHub write starts, then
/// ``updateOutcome(id:_:)`` right after gh returns. Both are synchronous writes (§4.3): never
/// wrap them in a task that can be cancelled before the commit. Combine an outcome with the
/// item's `synced_*` columns in one ``VaultDatabase/write(_:)`` using the `in:` overloads.
///
/// The journal drives crash and timeout reconciliation (``fetchEntries(states:)``), throttle
/// seeding (``writeStartTimes(accountLogin:since:)``), "remote added" suppression for names we
/// just deleted (``fetchSucceeded(repositoryID:commands:since:)``) and the last-run report
/// (``fetchLatestRun()``).
public struct SyncJournalStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    /// The final state and gh result of one journal row.
    public struct Outcome: Sendable, Hashable {
        public var state: SyncJournalState
        public var exitCode: Int?
        public var errorCode: String?
        public var finishedAt: Date?

        public init(state: SyncJournalState, exitCode: Int? = nil, errorCode: String? = nil, finishedAt: Date?) {
            self.state = state
            self.exitCode = exitCode
            self.errorCode = errorCode
            self.finishedAt = finishedAt
        }
    }

    // MARK: - Writes

    /// Inserts `entry` with state ``SyncJournalState/inFlight`` (whatever its `state` says) and
    /// returns it with its row id.
    @discardableResult
    public func appendInFlight(_ entry: SyncJournalRecord) throws -> SyncJournalRecord {
        try database.write { try appendInFlight(entry, in: $0) }
    }

    @discardableResult
    public func appendInFlight(_ entry: SyncJournalRecord, in tx: StoreTransaction) throws -> SyncJournalRecord {
        var row = entry
        row.id = nil
        row.state = .inFlight
        row.finishedAt = nil
        try row.insert(tx.db)
        return row
    }

    /// Inserts a row as given (for example a ``SyncJournalState/skipped`` item that never ran).
    @discardableResult
    public func append(_ entry: SyncJournalRecord) throws -> SyncJournalRecord {
        try database.write { try append(entry, in: $0) }
    }

    @discardableResult
    public func append(_ entry: SyncJournalRecord, in tx: StoreTransaction) throws -> SyncJournalRecord {
        var row = entry
        row.id = nil
        try row.insert(tx.db)
        return row
    }

    /// Records the outcome of row `id`. Throws ``StoreError/notFound`` if there is no such row.
    public func updateOutcome(id: Int64, _ outcome: Outcome) throws {
        try database.write { try updateOutcome(id: id, outcome, in: $0) }
    }

    public func updateOutcome(id: Int64, _ outcome: Outcome, in tx: StoreTransaction) throws {
        let changed = try SyncJournalRecord
            .filter(key: id)
            .updateAll(
                tx.db,
                SyncJournalRecord.CodingKeys.state.set(to: outcome.state.rawValue),
                SyncJournalRecord.CodingKeys.exitCode.set(to: outcome.exitCode),
                SyncJournalRecord.CodingKeys.errorCode.set(to: outcome.errorCode),
                SyncJournalRecord.CodingKeys.finishedAt.set(to: outcome.finishedAt.map(DatabaseTimestamp.string(from:)))
            )
        guard changed > 0 else {
            throw StoreError.notFound
        }
    }

    /// Records the verification baseline listed right before the write (§7.3). Throws
    /// ``StoreError/notFound`` if there is no such row.
    public func updatePreWriteUpdatedAt(id: Int64, _ date: Date?) throws {
        try database.write { try updatePreWriteUpdatedAt(id: id, date, in: $0) }
    }

    public func updatePreWriteUpdatedAt(id: Int64, _ date: Date?, in tx: StoreTransaction) throws {
        let changed = try SyncJournalRecord
            .filter(key: id)
            .updateAll(
                tx.db,
                SyncJournalRecord.CodingKeys.preWriteUpdatedAt.set(to: date.map(DatabaseTimestamp.string(from:)))
            )
        guard changed > 0 else {
            throw StoreError.notFound
        }
    }

    /// Retention (§6): deletes rows that started more than ``Timeouts/syncJournalRetention``
    /// before `now`, except rows of the latest run (the "last sync report") and unresolved
    /// ``SyncJournalState/inFlight`` rows, which launch reconciliation still needs. Returns the
    /// number of rows deleted.
    @discardableResult
    public func pruneExpired(now: Date) throws -> Int {
        try database.write { try pruneExpired(now: now, in: $0) }
    }

    @discardableResult
    public func pruneExpired(now: Date, in tx: StoreTransaction) throws -> Int {
        let cutoff = DatabaseTimestamp.string(from: now - Timeouts.syncJournalRetention.timeInterval)
        var request = SyncJournalRecord
            .filter(SyncJournalRecord.CodingKeys.startedAt < cutoff)
            .filter(SyncJournalRecord.CodingKeys.state != SyncJournalState.inFlight.rawValue)
        if let latestRunID = try Self.latestRunID(db: tx.db) {
            request = request.filter(SyncJournalRecord.CodingKeys.runID != latestRunID.uuidString)
        }
        return try request.deleteAll(tx.db)
    }

    // MARK: - Reads

    public func fetch(id: Int64) throws -> SyncJournalRecord? {
        try database.read { tx in try SyncJournalRecord.fetchOne(tx.db, key: id) }
    }

    /// Rows in any of `states`, oldest first (launch reconciliation of `in_flight` and
    /// `indeterminate` rows).
    public func fetchEntries(states: Set<SyncJournalState>) throws -> [SyncJournalRecord] {
        try database.read { tx in
            try SyncJournalRecord
                .filter(states.map(\.rawValue).contains(SyncJournalRecord.CodingKeys.state))
                .order(SyncJournalRecord.CodingKeys.id)
                .fetchAll(tx.db)
        }
    }

    /// The rows of one run, in the order they were written.
    public func fetchRun(_ runID: SyncRunID) throws -> [SyncJournalRecord] {
        try database.read { tx in try Self.run(runID, db: tx.db) }
    }

    /// The run of the most recently written row, or nil for an empty journal.
    public func latestRunID() throws -> SyncRunID? {
        try database.read { tx in try Self.latestRunID(db: tx.db) }
    }

    /// The rows of the latest run (the "last sync report"), in write order; empty if none.
    public func fetchLatestRun() throws -> [SyncJournalRecord] {
        try database.read { tx in try Self.latestRun(db: tx.db) }
    }

    /// The latest run's rows, now and after each change.
    public func observeLatestRun() -> AsyncThrowingStream<[SyncJournalRecord], any Error> {
        database.observe { db in try Self.latestRun(db: db) }
    }

    /// Start times (oldest first) of write commands for `accountLogin` (any case) that started at
    /// or after `since`, to seed the throttle at launch (D12): pass
    /// `now - Timeouts.throttleHourWindow`. Skipped rows never reached gh and are excluded.
    public func writeStartTimes(accountLogin: String, since: Date) throws -> [Date] {
        try database.read { tx in
            try SyncJournalRecord
                .filter(SyncJournalRecord.CodingKeys.accountLogin.collating(.nocase) == accountLogin)
                .filter(SyncJournalRecord.CodingKeys.isWrite == true)
                .filter(SyncJournalRecord.CodingKeys.state != SyncJournalState.skipped.rawValue)
                .filter(SyncJournalRecord.CodingKeys.startedAt >= DatabaseTimestamp.string(from: since))
                .order(SyncJournalRecord.CodingKeys.startedAt)
                .fetchAll(tx.db)
                .map(\.startedAt)
        }
    }

    /// Number of write commands for `accountLogin` since `since` (see
    /// ``writeStartTimes(accountLogin:since:)``).
    public func writeCount(accountLogin: String, since: Date) throws -> Int {
        try writeStartTimes(accountLogin: accountLogin, since: since).count
    }

    /// Succeeded rows of `repositoryID` whose command is in `commands`, started at or after
    /// `since`, oldest first. Drift uses it with the delete commands and
    /// `now - Timeouts.recentDeletionSuppression` to avoid reporting names we just deleted as
    /// "remote added" (§7.7).
    public func fetchSucceeded(repositoryID: RepoID, commands: Set<String>, since: Date) throws -> [SyncJournalRecord] {
        try database.read { tx in
            try SyncJournalRecord
                .filter(SyncJournalRecord.CodingKeys.repositoryID == repositoryID.uuidString)
                .filter(commands.contains(SyncJournalRecord.CodingKeys.command))
                .filter(SyncJournalRecord.CodingKeys.state == SyncJournalState.succeeded.rawValue)
                .filter(SyncJournalRecord.CodingKeys.startedAt >= DatabaseTimestamp.string(from: since))
                .order(SyncJournalRecord.CodingKeys.id)
                .fetchAll(tx.db)
        }
    }

    // MARK: - Queries

    static func latestRunID(db: Database) throws -> SyncRunID? {
        try SyncJournalRecord
            .select(SyncJournalRecord.CodingKeys.runID, as: String.self)
            .order(SyncJournalRecord.CodingKeys.id.desc)
            .fetchOne(db)
            .flatMap { SyncRunID(uuidString: $0) }
    }

    static func run(_ runID: SyncRunID, db: Database) throws -> [SyncJournalRecord] {
        try SyncJournalRecord
            .filter(SyncJournalRecord.CodingKeys.runID == runID.uuidString)
            .order(SyncJournalRecord.CodingKeys.id)
            .fetchAll(db)
    }

    static func latestRun(db: Database) throws -> [SyncJournalRecord] {
        guard let runID = try latestRunID(db: db) else { return [] }
        return try run(runID, db: db)
    }
}
