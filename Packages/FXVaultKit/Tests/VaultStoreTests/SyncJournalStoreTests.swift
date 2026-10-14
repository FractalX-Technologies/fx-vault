import Foundation
import Testing
import VaultCore
@testable import VaultStore

/// D28 journal: in-flight rows, outcomes, retention keeping the latest run, throttle seeding.
@Suite("SyncJournalStore")
struct SyncJournalStoreTests {
    static let hour = Timeouts.throttleHourWindow.timeInterval
    static let retention = Timeouts.syncJournalRetention.timeInterval

    @Test func appendInFlightThenRecordTheOutcome() throws {
        let seeded = try SeededDatabase()
        var entry = Sample.journal(runID: SyncRunID(), repositoryID: seeded.repo.id, startedAt: Sample.start)
        entry.state = .succeeded
        entry.finishedAt = Sample.date(1)
        let inserted = try seeded.journal.appendInFlight(entry)
        let id = try #require(inserted.id)
        #expect(inserted.state == .inFlight)
        #expect(inserted.finishedAt == nil)
        #expect(try seeded.journal.fetch(id: id) == inserted)
        #expect(try seeded.journal.fetchEntries(states: [.inFlight]).map(\.id) == [id])

        try seeded.journal.updatePreWriteUpdatedAt(id: id, Sample.date(-30))
        try seeded.journal.updateOutcome(id: id, .init(state: .failed, exitCode: 1, errorCode: "adminRequired", finishedAt: Sample.date(2)))
        let stored = try #require(try seeded.journal.fetch(id: id))
        #expect(stored.state == .failed)
        #expect(stored.exitCode == 1)
        #expect(stored.errorCode == "adminRequired")
        #expect(stored.finishedAt == Sample.date(2))
        #expect(stored.preWriteUpdatedAt == Sample.date(-30))
        #expect(try seeded.journal.fetchEntries(states: [.inFlight]).isEmpty)

        #expect(throws: StoreError.notFound) {
            try seeded.journal.updateOutcome(id: id + 1, .init(state: .succeeded, finishedAt: nil))
        }
        #expect(throws: StoreError.notFound) { try seeded.journal.updatePreWriteUpdatedAt(id: id + 1, nil) }
    }

    @Test func outcomeAndItemBookkeepingCommitTogether() throws {
        let seeded = try SeededDatabase()
        var item = Sample.item(repositoryID: seeded.repo.id)
        try seeded.config.insertItem(item)
        let entry = try seeded.journal.appendInFlight(Sample.journal(runID: SyncRunID(), repositoryID: seeded.repo.id, startedAt: Sample.start))
        let id = try #require(entry.id)

        // A failure inside the bookkeeping transaction leaves both rows untouched.
        #expect(throws: TestError.rollback) {
            try seeded.database.write { tx in
                try seeded.journal.updateOutcome(id: id, .init(state: .succeeded, exitCode: 0, finishedAt: Sample.date(1)), in: tx)
                throw TestError.rollback
            }
        }
        #expect(try seeded.journal.fetch(id: id)?.state == .inFlight)

        item.syncedName = item.name
        item.syncedValueCiphertext = item.valueCiphertext
        item.syncedFingerprint = item.valueFingerprint
        try seeded.database.write { tx in
            try seeded.journal.updateOutcome(id: id, .init(state: .succeeded, exitCode: 0, finishedAt: Sample.date(1)), in: tx)
            try seeded.config.updateItem(item, in: tx)
        }
        #expect(try seeded.journal.fetch(id: id)?.state == .succeeded)
        #expect(try seeded.config.fetchItems(repositoryID: seeded.repo.id).first?.syncStatus == .synced)
    }

    @Test func retentionKeepsTheLatestRunAndUnresolvedRows() throws {
        let seeded = try SeededDatabase()
        let now = Sample.date(10 * Self.retention)
        let expired = now - Self.retention - 1
        let fresh = now - Self.retention + 1

        let oldRun = SyncRunID()
        try seeded.journal.append(Self.finished(Sample.journal(runID: oldRun, repositoryID: seeded.repo.id, startedAt: expired)))
        try seeded.journal.append(Self.finished(Sample.journal(runID: oldRun, repositoryID: seeded.repo.id, startedAt: fresh)))
        let crashed = try seeded.journal.appendInFlight(Sample.journal(runID: oldRun, repositoryID: seeded.repo.id, startedAt: expired))

        // The latest run is old too, but it is the "last sync report".
        let latestRun = SyncRunID()
        try seeded.journal.append(Self.finished(Sample.journal(runID: latestRun, repositoryID: seeded.repo.id, startedAt: expired)))

        #expect(try seeded.journal.pruneExpired(now: now) == 1)
        #expect(try seeded.journal.latestRunID() == latestRun)
        #expect(try seeded.journal.fetchLatestRun().count == 1)
        #expect(try seeded.journal.fetchRun(oldRun).map(\.startedAt) == [fresh, expired])
        #expect(try seeded.journal.fetchEntries(states: [.inFlight]).map(\.id) == [crashed.id])
        #expect(try seeded.journal.pruneExpired(now: now) == 0)
    }

    @Test func emptyJournal() throws {
        let seeded = try SeededDatabase()
        #expect(try seeded.journal.latestRunID() == nil)
        #expect(try seeded.journal.fetchLatestRun().isEmpty)
        #expect(try seeded.journal.pruneExpired(now: Sample.start) == 0)
    }

    @Test func writeStartTimesSeedTheThrottlePerAccount() throws {
        let seeded = try SeededDatabase()
        let now = Sample.date(Self.hour * 2)
        let since = now - Self.hour
        let run = SyncRunID()
        let inWindow = [now - 30, now - 10]

        for start in inWindow.reversed() {
            try seeded.journal.append(Self.finished(Sample.journal(runID: run, account: Sample.login.uppercased(), repositoryID: nil, startedAt: start)))
        }
        // Excluded: too old, a read, skipped, another account.
        try seeded.journal.append(Self.finished(Sample.journal(runID: run, repositoryID: nil, startedAt: since - 1)))
        try seeded.journal.append(Self.finished(Sample.journal(runID: run, repositoryID: nil, command: "secret.list", isWrite: false, startedAt: now - 5)))
        var skipped = Sample.journal(runID: run, repositoryID: nil, startedAt: now - 5)
        skipped.state = .skipped
        try seeded.journal.append(skipped)
        try seeded.journal.append(Self.finished(Sample.journal(runID: run, account: "someone-else", repositoryID: nil, startedAt: now - 5)))
        // An in-flight write counts: it may have reached GitHub.
        try seeded.journal.appendInFlight(Sample.journal(runID: run, repositoryID: nil, startedAt: now - 1))

        #expect(try seeded.journal.writeStartTimes(accountLogin: Sample.login, since: since) == inWindow + [now - 1])
        #expect(try seeded.journal.writeCount(accountLogin: Sample.login, since: since) == inWindow.count + 1)
    }

    @Test func recentSuccessfulDeletesForDriftSuppression() throws {
        let seeded = try SeededDatabase()
        let now = Sample.date(Timeouts.recentDeletionSuppression.timeInterval * 2)
        let since = now - Timeouts.recentDeletionSuppression.timeInterval
        let run = SyncRunID()
        let deletes: Set<String> = ["secret.delete", "variable.delete"]

        try seeded.journal.append(Self.finished(Sample.journal(runID: run, repositoryID: seeded.repo.id, command: "secret.delete", itemName: "OLD", startedAt: now - 60)))
        try seeded.journal.append(Self.finished(Sample.journal(runID: run, repositoryID: seeded.repo.id, command: "secret.delete", itemName: "ANCIENT", startedAt: since - 1)))
        try seeded.journal.append(Self.finished(Sample.journal(runID: run, repositoryID: seeded.repo.id, command: "secret.set", itemName: "NEW", startedAt: now - 60)))
        var failed = Self.finished(Sample.journal(runID: run, repositoryID: seeded.repo.id, command: "variable.delete", itemName: "FAILED", startedAt: now - 60))
        failed.state = .failed
        try seeded.journal.append(failed)

        let names = try seeded.journal.fetchSucceeded(repositoryID: seeded.repo.id, commands: deletes, since: since).map(\.itemName)
        #expect(names == ["OLD"])
    }

    static func finished(_ entry: SyncJournalRecord) -> SyncJournalRecord {
        var entry = entry
        entry.state = .succeeded
        entry.exitCode = 0
        entry.finishedAt = entry.startedAt
        return entry
    }
}
