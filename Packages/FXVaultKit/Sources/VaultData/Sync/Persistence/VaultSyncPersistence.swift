import Foundation
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// SyncEngine's `SyncPersisting` over the vault database (§7.3, §7.4, D28).
///
/// - Journal rows go to `sync_journal` through `SyncJournalStore`; every call is a synchronous
///   write (DATABASE.md "Transactions").
/// - ``commit(_:)`` applies the journal outcomes and the row effects in **one** transaction.
///   A commit whose effects need keys (a pushed value is re-sealed as the synced value) runs in
///   `VaultSession.write`, so it is serialized with DEK rotation and refused while locked;
///   anything else is plain bookkeeping and runs in `VaultDatabase.write`, so a failure can still
///   be recorded after the vault locked.
/// - Store failures map to `SyncError.persistenceFailed`, a locked vault to `.locked`.
struct VaultSyncPersistence: SyncPersisting {
    let session: VaultSession
    /// Stamps rows that effects create (tombstones).
    let clock: any VaultClock

    private var journal: SyncJournalStore {
        SyncJournalStore(database: session.database)
    }

    // MARK: - SyncPersisting

    func appendJournal(_ entry: SyncJournalEntryModel) throws(SyncError) -> SyncJournalEntryID {
        let stored = try Self.perform { try journal.append(SyncJournalMapper.record(entry)) }
        guard let id = stored.id else { throw .persistenceFailed }
        return SyncJournalEntryID(id)
    }

    func commit(_ commit: SyncCommitModel) throws(SyncError) {
        guard !commit.isEmpty else { return }
        let database = session.database
        let now = clock.now
        if commit.effects.contains(where: SyncEffectApplier.needsKeys) {
            try Self.perform {
                try session.write { keys, tx in
                    let rows = SyncRowWriter(database: database, tx: tx, now: now)
                    try Self.apply(commit, applier: SyncEffectApplier(rows: rows, keys: copy keys))
                }
            }
        } else {
            try Self.perform {
                try database.write { tx in
                    let rows = SyncRowWriter(database: database, tx: tx, now: now)
                    try Self.apply(commit, applier: SyncEffectApplier(rows: rows, keys: nil))
                }
            }
        }
    }

    func journalEntries(states: Set<SyncJournalOutcomeState>) throws(SyncError) -> [SyncJournalEntryModel] {
        let storeStates = Set(states.map(SyncJournalMapper.storeState))
        return try Self.perform { try journal.fetchEntries(states: storeStates) }
            .compactMap(SyncJournalMapper.model)
    }

    func journalEntries(repositoryID: RepoID, since: Date) throws(SyncError) -> [SyncJournalEntryModel] {
        // The journal keeps 24 hours (§6), so reading every row and filtering stays small.
        let all = try Self.perform { try journal.fetchEntries(states: Set(SyncJournalState.allCases)) }
        return all
            .filter { $0.repositoryID == repositoryID && $0.startedAt >= since }
            .compactMap(SyncJournalMapper.model)
    }

    func writeStartTimes(accountLogin: String, since: Date) throws(SyncError) -> [Date] {
        try Self.perform { try journal.writeStartTimes(accountLogin: accountLogin, since: since) }
    }

    // MARK: - Helpers

    /// Journal outcomes first, then the effects in order.
    private static func apply(_ commit: SyncCommitModel, applier: SyncEffectApplier) throws {
        let journal = SyncJournalStore(database: applier.rows.database)
        for update in commit.journal {
            do {
                try journal.updateOutcome(
                    id: update.id.rawValue,
                    SyncJournalMapper.outcome(update.outcome),
                    in: applier.rows.tx
                )
            } catch StoreError.notFound {
                // The row was pruned meanwhile; its outcome no longer matters (reference fake).
                continue
            }
        }
        for effect in commit.effects {
            try applier.apply(effect)
        }
    }

    /// Runs `body`, mapping any failure to ``SyncError``.
    static func perform<Result>(_ body: () throws -> Result) throws(SyncError) -> Result {
        do {
            return try body()
        } catch {
            throw map(error)
        }
    }

    static func map(_ error: any Error) -> SyncError {
        switch error {
        case let error as SyncError:
            error
        case VaultError.locked, VaultError.notInitialized:
            .locked
        default:
            .persistenceFailed
        }
    }
}

/// SyncEngine's `SyncValueProviding` over `VaultSession` (§5.4): values are decrypted inside
/// `VaultSession.read`, so a concurrent DEK rotation can never pair them with the wrong key.
struct VaultSyncValues: SyncValueProviding {
    let session: VaultSession

    func ensureUnlocked() throws(SyncError) {
        guard !session.isLocked else { throw .locked }
    }

    /// The decrypted `value_ct` with the `value_fp` it was read with, or nil when the value is
    /// missing or the row no longer exists (the executor then reports it as value-missing
    /// instead of stopping the run).
    func value(of itemID: ConfigItemID) throws(SyncError) -> SyncItemValueModel? {
        let store = ConfigStore(database: session.database)
        return try VaultSyncPersistence.perform {
            try session.read { keys, tx -> SyncItemValueModel? in
                guard let record = try store.fetchItemRecord(id: itemID, in: tx),
                      let fingerprint = record.valueFingerprint
                else { return nil }
                let value: SecretBytes?
                do {
                    value = try ConfigFieldCipher.openValue(of: record, keys: keys)
                } catch VaultError.locked {
                    throw VaultError.locked
                } catch {
                    throw SyncError.valueUnavailable(itemID)
                }
                return value.map { SyncItemValueModel(value: $0, fingerprint: fingerprint) }
            }
        }
    }

    func fingerprint(_ value: SecretBytes, rowID: ConfigItemID) throws(SyncError) -> Data {
        try VaultSyncPersistence.perform {
            try session.withKeys { $0.fingerprint(value, rowID: rowID) }
        }
    }
}
