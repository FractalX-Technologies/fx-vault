import Foundation
import GitHubKit
import VaultCore

/// The vault database as the sync engine sees it (tasks/todo.md §7.3, §7.4, D28). VaultData
/// implements it over `SyncJournalStore` and `ConfigStore`; tests use ``InMemorySyncVault``.
///
/// Every call is synchronous (database writes never span a suspension point, DATABASE.md
/// "Transactions") and maps store failures to ``SyncError/persistenceFailed`` and a locked vault
/// to ``SyncError/locked``.
public protocol SyncPersisting: Sendable {
    /// Appends an `in_flight` row **before** a gh write (or a journaled read such as the
    /// preflight B2 lookup) and returns its id.
    func appendJournal(_ entry: SyncJournalEntryModel) throws(SyncError) -> SyncJournalEntryID

    /// Applies journal outcomes and row effects in **one** write transaction.
    func commit(_ commit: SyncCommitModel) throws(SyncError)

    /// Rows in any of `states` (launch reconciliation reads `in_flight` and `indeterminate`).
    func journalEntries(states: Set<SyncJournalOutcomeState>) throws(SyncError) -> [SyncJournalEntryModel]

    /// Rows of one repository started at or after `since`, oldest first (create
    /// reconciliation, "is this remote environment ours?").
    func journalEntries(repositoryID: RepoID, since: Date) throws(SyncError) -> [SyncJournalEntryModel]

    /// Start times of the account's gh writes since `since` (throttle seeding, D12).
    func writeStartTimes(accountLogin: String, since: Date) throws(SyncError) -> [Date]
}

/// Decrypted values and row-bound fingerprints, inside the keyring scope (§5.4). VaultData
/// implements it over `VaultSession.read` (rotation-safe); SyncEngine never touches the
/// database or the keys.
public protocol SyncValueProviding: Sendable {
    /// Throws ``SyncError/locked`` when the vault is locked.
    func ensureUnlocked() throws(SyncError)

    /// The current local value of `itemID` (`value_ct`), or nil when it is missing. The caller
    /// owns the returned buffer and wipes it.
    func value(of itemID: ConfigItemID) throws(SyncError) -> SyncItemValueModel?

    /// The row-bound fingerprint of `value` (`UnlockedKeys.fingerprint(_:rowID:)`).
    func fingerprint(_ value: SecretBytes, rowID: ConfigItemID) throws(SyncError) -> Data
}

/// A decrypted value with the `value_fp` it was read with.
public struct SyncItemValueModel: Sendable {
    public let value: SecretBytes
    /// `value_fp` at read time (``ItemPushedEffectModel/sourceFingerprint``).
    public let fingerprint: Data

    public init(value: SecretBytes, fingerprint: Data) {
        self.value = value
        self.fingerprint = fingerprint
    }

    public func wipe() {
        value.wipe()
    }
}

/// One ``GHCommandScheduler`` per account (D12), looked up by login (case-insensitive).
public struct SyncSchedulerRegistry: Sendable {
    private let schedulers: [String: GHCommandScheduler]

    public init(_ schedulers: [GHCommandScheduler]) {
        var byLogin: [String: GHCommandScheduler] = [:]
        for scheduler in schedulers {
            byLogin[OwnerLoginValidator.foldKey(scheduler.accountLogin)] = scheduler
        }
        self.schedulers = byLogin
    }

    /// The scheduler of `login`, or nil.
    public func scheduler(for login: String) -> GHCommandScheduler? {
        schedulers[OwnerLoginValidator.foldKey(login)]
    }

    /// Every registered scheduler.
    public var all: [GHCommandScheduler] {
        Array(schedulers.values)
    }

    func require(_ login: String) throws(SyncError) -> GHCommandScheduler {
        guard let scheduler = scheduler(for: login) else { throw .accountUnavailable(login) }
        return scheduler
    }
}

/// Seeds a scheduler's write throttle from the journal (D12: "seeded at launch from
/// `sync_journal`"). Call **once** per scheduler, right after creating it: seeding appends.
public enum SyncThrottleSeeder {
    /// Seeds `scheduler` with the account's writes of the last `Timeouts.throttleHourWindow`.
    /// Each journal row counts `Limits.defaultWriteCost` (the journal keeps no cost; a variable
    /// update's second request is not counted, so the seed is a lower bound).
    public static func seed(
        _ scheduler: GHCommandScheduler,
        from persistence: any SyncPersisting,
        clock: any VaultClock
    ) async throws(SyncError) {
        let since = clock.now.addingTimeInterval(-Timeouts.throttleHourWindow.timeInterval)
        let starts = try persistence.writeStartTimes(accountLogin: scheduler.accountLogin, since: since)
        await scheduler.seed(recentWrites: starts.map { GHWriteRecordModel(date: $0, cost: Limits.defaultWriteCost) })
    }
}
