import DestinationKit
import EnvTools
import Foundation
import os
import VaultCore
import VaultCrypto
import VaultStore

/// How VaultData reaches a destination's provider (v0.8.0). The live implementation wraps
/// DestinationKit's ``DestinationRemoteFactory``; tests use an in-memory remote.
public protocol DestinationRemoteProviding: Sendable {
    /// A client for `destination`.
    func remote(for destination: DestinationModel) async throws(DestinationError) -> any DestinationRemoting
}

/// The live provider access: DestinationKit's HTTPS clients and the `az` token provider.
public struct LiveDestinationRemoteProvider: DestinationRemoteProviding {
    private let factory: DestinationRemoteFactory

    public init(factory: DestinationRemoteFactory) {
        self.factory = factory
    }

    public func remote(for destination: DestinationModel) async throws(DestinationError) -> any DestinationRemoting {
        try factory.remote(for: destination.target)
    }
}

/// The destination side of Sync, Refresh and import (v0.8.0, tasks/todo.md R5, R6).
///
/// - **Review** lists every destination with pending changes and blocks what cannot be sent:
///   a missing value, a listing failure, an item that changed remotely since the last sync
///   (optimistic concurrency), a new item the remote already has.
/// - **Run** lists each destination again right before writing, journals every write
///   `in_flight` first, writes, records the new sync state, then re-lists once to confirm
///   by a new version. An unconfirmed write
///   is pushed again on the next Sync.
/// - **Refresh** reports remote adds, changes and deletions since the last sync; **resolve**
///   applies Keep Mine or Use Remote after checking the remote did not move again.
/// - Values are decrypted only to be sent or classified and are wiped right after. Logs carry
///   counts and codes only.
public actor DestinationSyncRepository {
    private let session: VaultSession
    private let remotes: any DestinationRemoteProviding
    private let clock: any VaultClock

    public init(session: VaultSession, remotes: any DestinationRemoteProviding, clock: any VaultClock = SystemClock()) {
        self.session = session
        self.remotes = remotes
        self.clock = clock
    }

    private var store: DestinationStore {
        DestinationStore(database: session.database)
    }

    private var repository: DestinationRepository {
        DestinationRepository(session: session, clock: clock)
    }

    // MARK: - Review

    /// The destination changes of `repositoryID` (nil: the Key Vaults of their own), listed and
    /// checked (no writes except journal reconciliation). Destinations without pending changes
    /// are not contacted.
    public func review(repositoryID: RepoID?) async -> DestinationReviewModel {
        guard let destinations = try? repository.destinations(repositoryID: repositoryID) else {
            return .empty(repositoryID)
        }
        var sections: [DestinationReviewSectionModel] = []
        for destination in destinations where destination.pendingCount > 0 {
            sections.append(await reviewSection(destination))
        }
        return DestinationReviewModel(repositoryID: repositoryID, sections: sections)
    }

    private func reviewSection(_ destination: DestinationModel) async -> DestinationReviewSectionModel {
        let listed: [RemoteDestinationItemModel]
        do throws(DestinationSyncError) {
            let remote = try await self.remote(for: destination)
            listed = try await listing(remote, of: destination)
        } catch {
            let reason: DestinationBlockReason = switch error {
            case .remote(let remoteError): .listingFailed(remoteError)
            case .config, .stale: .listingFailed(.decoding)
            }
            let rows = (try? pendingRows(destination.id)) ?? []
            let held = rows.filter(Self.isHeld)
            return DestinationReviewSectionModel(
                destination: destination,
                changes: [],
                blocked: rows.filter { !Self.isHeld($0) }.map {
                    DestinationBlockedChangeModel(change: change(for: $0, in: destination, remote: nil), reason: reason)
                },
                held: held.compactMap { row in
                    row.shareHold.map {
                        DestinationHeldChangeModel(change: change(for: row, in: destination, remote: nil), packageID: $0, reason: reason)
                    }
                }
            )
        }
        try? reconcileJournal(destination, listed: listed)
        let byName = Self.usableByName(listed)
        let rows = (try? pendingRows(destination.id)) ?? []
        var changes: [DestinationChangeModel] = []
        var blocked: [DestinationBlockedChangeModel] = []
        var held: [DestinationHeldChangeModel] = []
        for row in rows {
            guard let operation = row.pendingOperation else { continue }
            let remoteItem = byName[GitHubNameValidator.foldKey(row.name)]
            let change = change(for: row, in: destination, remote: remoteItem)
            let reason = blockReason(for: row, operation: operation, remote: remoteItem, destination: destination)
            if Self.isHeld(row), let packageID = row.shareHold {
                held.append(DestinationHeldChangeModel(change: change, packageID: packageID, reason: reason))
            } else if let reason {
                blocked.append(DestinationBlockedChangeModel(change: change, reason: reason))
            } else {
                changes.append(change)
            }
        }
        changes.sort { ($0.operation == .delete ? 1 : 0, $0.name) < ($1.operation == .delete ? 1 : 0, $1.name) }
        held.sort { $0.change.name < $1.change.name }
        return DestinationReviewSectionModel(destination: destination, changes: changes, blocked: blocked, held: held)
    }

    /// A row a share file holds (v0.9.0, P8). A deletion is the user's own change and is never
    /// held.
    private static func isHeld(_ row: DestinationItemRecord) -> Bool {
        row.shareHold != nil && row.pendingOperation != .delete
    }

    private func blockReason(
        for row: DestinationItemRecord,
        operation: DestinationPendingOperation,
        remote: RemoteDestinationItemModel?,
        destination: DestinationModel
    ) -> DestinationBlockReason? {
        if operation != .delete, let violation = DestinationRules.violation(of: row.name, kind: row.kind, provider: destination.provider) {
            return .invalidName(violation)
        }
        switch operation {
        case .add:
            if row.valueCiphertext == nil { return .valueMissing }
            if remote != nil { return .existsRemotely }
        case .update:
            guard let remote, remote.version == row.remoteVersion else { return .remoteChanged }
        case .delete:
            if let remote, remote.version != row.remoteVersion { return .remoteChanged }
        }
        return nil
    }

    // MARK: - Run

    /// Sends the review's sendable changes, destination by destination; deletions only with
    /// `includeDeletions` (after the user confirmed them). Rows held by share files run only when
    /// their file is in `includeHeld` (Sync's From Files review, v0.9.0, the same set the GitHub
    /// run got): those files' destination holds are released first, in one transaction.
    public func run(
        _ review: DestinationReviewModel,
        includeDeletions: Bool,
        includeHeld: Set<SharePackageID> = [],
        progress: @Sendable (DestinationProgressEvent) -> Void = { _ in }
    ) async -> DestinationRunResultModel {
        var result = DestinationRunResultModel()
        let runID = SyncRunID()
        let released = includeHeld.isEmpty ? [] : releaseHolds(includeHeld, in: review)
        for section in review.sections {
            let heldWrites = section.heldWrites(including: includeHeld).filter { released.contains($0.itemID) }
            let changes = (includeDeletions ? section.changes : section.writes) + heldWrites
            for skipped in section.changes where !changes.contains(skipped) {
                result.outcomes[skipped.id] = .skipped
            }
            guard !changes.isEmpty else { continue }
            let outcomes = await runSection(section.destination, changes: changes, runID: runID, progress: progress)
            result.outcomes.merge(outcomes) { _, new in new }
        }
        Self.log.info("Destination sync: \(result.doneCount, privacy: .public) done, \(result.failedCount, privacy: .public) failed, \(result.blockedCount, privacy: .public) blocked")
        return result
    }

    private func runSection(
        _ destination: DestinationModel,
        changes: [DestinationChangeModel],
        runID: SyncRunID,
        progress: @Sendable (DestinationProgressEvent) -> Void
    ) async -> [String: DestinationChangeOutcome] {
        var outcomes: [String: DestinationChangeOutcome] = [:]
        let remote: any DestinationRemoting
        let listed: [RemoteDestinationItemModel]
        do throws(DestinationSyncError) {
            remote = try await self.remote(for: destination)
            listed = try await listing(remote, of: destination)
        } catch {
            let outcome: DestinationChangeOutcome = switch error {
            case .remote(let remoteError): .failed(remoteError)
            case .config, .stale: .failed(.decoding)
            }
            for change in changes {
                outcomes[change.id] = outcome
            }
            return outcomes
        }
        let byName = Self.usableByName(listed)
        var pushed: [PushedWrite] = []
        for change in changes {
            if Task.isCancelled {
                outcomes[change.id] = .skipped
                continue
            }
            progress(.started(changeID: change.id))
            let outcome = await execute(change, destination: destination, remote: remote, byName: byName, runID: runID, pushed: &pushed)
            outcomes[change.id] = outcome
            progress(.finished(changeID: change.id, outcome: outcome))
        }
        if !pushed.isEmpty {
            for (id, outcome) in await confirm(pushed, destination: destination, remote: remote) {
                outcomes[id] = outcome
            }
        }
        try? touchRefreshed(destination.id)
        return outcomes
    }

    /// A write that succeeded, waiting for the confirming re-list.
    private struct PushedWrite {
        let change: DestinationChangeModel
        let itemID: ConfigItemID
        let preWriteVersion: String?
        let resultVersion: String?
    }

    private func execute(
        _ change: DestinationChangeModel,
        destination: DestinationModel,
        remote: any DestinationRemoting,
        byName: [String: RemoteDestinationItemModel],
        runID: SyncRunID,
        pushed: inout [PushedWrite]
    ) async -> DestinationChangeOutcome {
        guard let row = try? store.fetchItemRecord(id: change.itemID),
              row.pendingOperation == change.operation,
              !Self.isHeld(row)
        else {
            return .skipped
        }
        let remoteItem = byName[GitHubNameValidator.foldKey(row.name)]
        if change.operation == .delete, remoteItem == nil {
            try? finalizeDeletion(row.id)
            return .done
        }
        if let reason = blockReason(for: row, operation: change.operation, remote: remoteItem, destination: destination) {
            return .blocked(reason)
        }
        switch change.operation {
        case .add, .update:
            guard let opened = try? openValue(row) else {
                return .blocked(.valueMissing)
            }
            defer { opened.value.wipe() }
            // The fingerprint is journaled before the write, so an interrupted run settles the
            // value that was sent, not one edited since.
            guard var journal = try? beginJournal(
                change,
                row: row,
                runID: runID,
                preWriteVersion: remoteItem?.version,
                pushedFingerprint: opened.fingerprint
            ) else {
                return .failed(.decoding)
            }
            do throws(DestinationError) {
                let written = try await remote.setValue(opened.value, name: row.name, kind: row.kind, existing: remoteItem)
                try? recordPush(row.id, pushedFingerprint: opened.fingerprint, kind: row.kind, written: written, existing: remoteItem)
                try? finishJournal(&journal, state: .succeeded, error: nil)
                pushed.append(PushedWrite(
                    change: change,
                    itemID: row.id,
                    preWriteVersion: remoteItem?.version,
                    resultVersion: written.version
                ))
                return .done
            } catch {
                try? finishJournal(&journal, state: error.reachedProvider ? .failed : .indeterminate, error: error.logCode)
                return .failed(error)
            }
        case .delete:
            guard let remoteItem else { return .done }
            guard var journal = try? beginJournal(change, row: row, runID: runID, preWriteVersion: remoteItem.version, pushedFingerprint: nil) else {
                return .failed(.decoding)
            }
            do throws(DestinationError) {
                try await remote.delete(remoteItem)
            } catch .notFound {
                // Already gone: nothing left to delete.
            } catch {
                try? finishJournal(&journal, state: error.reachedProvider ? .failed : .indeterminate, error: error.logCode)
                return .failed(error)
            }
            try? finalizeDeletion(row.id)
            try? finishJournal(&journal, state: .succeeded, error: nil)
            return .done
        }
    }

    /// Re-lists once after the writes: a write is confirmed when the remote lists the item with
    /// the version the write returned or a version other than the one before the write. Unconfirmed writes are pushed again on the next Sync.
    private func confirm(
        _ writes: [PushedWrite],
        destination: DestinationModel,
        remote: any DestinationRemoting
    ) async -> [String: DestinationChangeOutcome] {
        let relisted: [String: RemoteDestinationItemModel]
        do throws(DestinationSyncError) {
            relisted = Self.usableByName(try await listing(remote, of: destination))
        } catch {
            return Dictionary(uniqueKeysWithValues: writes.map { ($0.change.id, DestinationChangeOutcome.unconfirmed) })
        }
        var outcomes: [String: DestinationChangeOutcome] = [:]
        for write in writes {
            let listed = relisted[GitHubNameValidator.foldKey(write.change.name)]
            let confirmed = listed.map { Self.isConfirmed(write, listed: $0) } ?? false
            try? recordConfirmation(write.itemID, listed: confirmed ? listed : nil)
            outcomes[write.change.id] = confirmed ? .done : .unconfirmed
        }
        return outcomes
    }

    private static func isConfirmed(_ write: PushedWrite, listed: RemoteDestinationItemModel) -> Bool {
        if let version = write.resultVersion {
            return listed.version == version || listed.version != write.preWriteVersion
        }
        return listed.version != write.preWriteVersion || write.preWriteVersion == nil
    }

    // MARK: - Refresh and drift (R6)

    /// Lists the destination and reports how it differs from what the vault last synced. A
    /// tombstone whose item is already gone remotely is cleared here.
    public func refresh(destinationID: DestinationID) async throws(DestinationSyncError) -> DestinationRefreshModel {
        let destination = try loadDestination(destinationID)
        let remote = try await self.remote(for: destination)
        let listed = try await listing(remote, of: destination)
        let now = clock.now
        let rows: [DestinationItemRecord]
        let recentlyDeleted: Set<String>
        do {
            (rows, recentlyDeleted) = try session.database.read { tx in
                (
                    try store.fetchItemRecords(destinationID: destinationID, in: tx),
                    try store.recentlyDeletedNames(destinationID: destinationID, since: now - Timeouts.recentDeletionSuppression.timeInterval, in: tx)
                )
            }
        } catch {
            throw .config(.wrap(error))
        }
        let byName = Self.usableByName(listed)
        let rowsByName = Dictionary(rows.map { (GitHubNameValidator.foldKey($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        var findings: [DestinationDriftModel] = []
        var goneTombstones: [ConfigItemID] = []
        for (key, item) in byName.sorted(by: { $0.key < $1.key }) {
            guard let name = item.name else { continue }
            if let row = rowsByName[key] {
                if !row.isSynced, !row.isDeleted {
                    findings.append(finding(.remoteAdded, destination: destination, name: name, item: item, row: row))
                }
                continue
            }
            guard !recentlyDeleted.contains(GitHubNameValidator.normalize(name)) else { continue }
            findings.append(finding(.remoteAdded, destination: destination, name: name, item: item, row: nil))
        }
        for row in rows where row.isSynced {
            let key = GitHubNameValidator.foldKey(row.syncedName ?? row.name)
            let item = byName[key]
            if row.isDeleted {
                if item == nil { goneTombstones.append(row.id) }
                continue
            }
            guard let item else {
                findings.append(finding(.remoteDeleted, destination: destination, name: row.name, item: nil, row: row))
                continue
            }
            if item.version != row.remoteVersion || item.kind != row.syncedKind {
                findings.append(finding(.remoteChanged, destination: destination, name: row.name, item: item, row: row))
            }
        }
        for id in goneTombstones {
            try? finalizeDeletion(id)
        }
        try? touchRefreshed(destinationID)
        let unusable = listed.compactMap { item in
            item.unusableReason.map { DestinationUnusableItemModel(remoteName: item.remoteName, reason: $0) }
        }
        return DestinationRefreshModel(destinationID: destinationID, findings: findings, unusable: unusable, listedAt: now)
    }

    private func finding(
        _ kind: DestinationDriftKind,
        destination: DestinationModel,
        name: String,
        item: RemoteDestinationItemModel?,
        row: DestinationItemRecord?
    ) -> DestinationDriftModel {
        let canKeepMine: Bool = switch kind {
        case .remoteAdded: true
        case .remoteChanged, .remoteDeleted: row?.valueCiphertext != nil
        }
        return DestinationDriftModel(
            destinationID: destination.id,
            kind: kind,
            name: name,
            remoteName: item?.remoteName ?? DestinationRules.remoteName(for: name, provider: destination.provider),
            itemID: row?.id,
            remoteKind: item?.kind,
            isValueReadable: item?.isValueReadable ?? false,
            canKeepMine: canKeepMine
        )
    }

    /// Applies one choice to findings of one destination. The destination is listed again first;
    /// a finding that no longer holds throws `.stale` and nothing is written.
    public func resolve(
        _ findings: [DestinationDriftModel],
        choice: DestinationDriftChoice,
        destinationID: DestinationID
    ) async throws(DestinationSyncError) {
        guard !findings.isEmpty else { return }
        let destination = try loadDestination(destinationID)
        let remote = try await self.remote(for: destination)
        let current = try await refresh(destinationID: destinationID)
        let currentIDs = Set(current.findings.map(\.id))
        guard findings.allSatisfy({ currentIDs.contains($0.id) && $0.destinationID == destinationID }) else {
            throw .stale
        }
        if choice == .keepMine, findings.contains(where: { !$0.canKeepMine }) {
            throw .config(.valueMissing)
        }
        let listed = Self.usableByName(try await listing(remote, of: destination))
        var values: [String: SecretBytes] = [:]
        defer { values.values.forEach { $0.wipe() } }
        if choice == .useRemote {
            for finding in findings where finding.kind != .remoteDeleted && finding.isValueReadable {
                guard let item = listed[GitHubNameValidator.foldKey(finding.name)] else { throw .stale }
                do throws(DestinationError) {
                    values[finding.id] = try await remote.readValue(of: item)
                } catch {
                    throw .remote(error)
                }
            }
        }
        let now = clock.now
        do {
            try session.write { keys, tx in
                for finding in findings {
                    try apply(finding, choice: choice, item: listed[GitHubNameValidator.foldKey(finding.name)], value: values[finding.id], keys: keys, tx: tx, now: now)
                }
            }
        } catch {
            throw .config(.wrap(error))
        }
        Self.log.info("Resolved \(findings.count, privacy: .public) destination differences")
    }

    /// Imports what a destination already holds (right after it is added): every usable remote
    /// item the vault does not have becomes a synced row, with its value where the provider
    /// returns one.
    @discardableResult
    public func importRemote(destinationID: DestinationID) async throws(DestinationSyncError) -> DestinationImportResultModel {
        let refreshed = try await refresh(destinationID: destinationID)
        var result = DestinationImportResultModel()
        result.unusable = refreshed.unusable
        let adds = refreshed.findings.filter { $0.kind == .remoteAdded && $0.itemID == nil }
        result.conflicts = refreshed.findings.filter { $0.kind == .remoteAdded && $0.itemID != nil }.map(\.name)
        guard !adds.isEmpty else { return result }
        try await resolve(adds, choice: .useRemote, destinationID: destinationID)
        result.imported = adds.map(\.name)
        result.withoutValue = adds.filter { !$0.isValueReadable }.map(\.name)
        return result
    }

    private func apply(
        _ finding: DestinationDriftModel,
        choice: DestinationDriftChoice,
        item: RemoteDestinationItemModel?,
        value: SecretBytes?,
        keys: borrowing UnlockedKeys,
        tx: StoreTransaction,
        now: Date
    ) throws {
        let store = store
        switch (finding.kind, choice) {
        case (.remoteAdded, _):
            guard let item else { throw DestinationSyncError.stale }
            if let itemID = finding.itemID, var row = try store.fetchItemRecord(id: itemID, in: tx) {
                row.syncedName = row.name
                row.syncedKind = item.kind
                row.remoteVersion = item.version
                row.updatedAt = now
                if choice == .useRemote {
                    try Self.take(value, kind: item.kind, into: &row, keys: keys)
                } else {
                    row.syncedFingerprint = nil
                    row.forcePush = true
                }
                try store.updateItem(row, in: tx)
                return
            }
            guard try store.countLiveItems(destinationID: finding.destinationID, in: tx) < Limits.maxDestinationItems else {
                throw ConfigRepositoryError.destinationFull(limit: Limits.maxDestinationItems)
            }
            var row = DestinationItemRecord(
                destinationID: finding.destinationID,
                kind: item.kind,
                name: finding.name,
                valueCiphertext: nil,
                valueFingerprint: nil,
                isDeleted: choice == .keepMine,
                syncedName: finding.name,
                syncedKind: item.kind,
                remoteVersion: item.version,
                createdAt: now,
                updatedAt: now
            )
            if choice == .useRemote {
                try Self.take(value, kind: item.kind, into: &row, keys: keys)
            }
            try store.insertItem(row, in: tx)
        case (.remoteChanged, .useRemote):
            guard let item, let itemID = finding.itemID, var row = try store.fetchItemRecord(id: itemID, in: tx) else {
                throw DestinationSyncError.stale
            }
            row.syncedKind = item.kind
            row.remoteVersion = item.version
            row.forcePush = false
            row.updatedAt = now
            try Self.take(value, kind: item.kind, into: &row, keys: keys)
            try store.updateItem(row, in: tx)
        case (.remoteChanged, .keepMine):
            guard let item, let itemID = finding.itemID, var row = try store.fetchItemRecord(id: itemID, in: tx) else {
                throw DestinationSyncError.stale
            }
            row.syncedKind = item.kind
            row.remoteVersion = item.version
            row.forcePush = true
            row.updatedAt = now
            try store.updateItem(row, in: tx)
        case (.remoteDeleted, .useRemote):
            guard let itemID = finding.itemID else { throw DestinationSyncError.stale }
            try store.deleteItem(id: itemID, in: tx)
        case (.remoteDeleted, .keepMine):
            guard let itemID = finding.itemID, var row = try store.fetchItemRecord(id: itemID, in: tx), row.valueCiphertext != nil else {
                throw DestinationSyncError.stale
            }
            row.syncedName = nil
            row.syncedKind = nil
            row.syncedFingerprint = nil
            row.remoteVersion = nil
            row.forcePush = false
            row.updatedAt = now
            try store.updateItem(row, in: tx)
        }
    }

    /// Gives `row` the remote's value (or none, for a write-only value) and kind, as synced.
    private static func take(_ value: SecretBytes?, kind: ConfigKind, into row: inout DestinationItemRecord, keys: borrowing UnlockedKeys) throws {
        row.kind = kind
        if let value {
            let normalized = try ValueNormalizer.normalize(value)
            defer { normalized.value.wipe() }
            try DestinationFieldCipher.setValue(normalized.value, on: &row, keys: keys)
            row.syncedFingerprint = row.valueFingerprint
        } else {
            guard kind == .secret else { throw ConfigRepositoryError.valueMissing }
            row.valueCiphertext = nil
            row.valueFingerprint = nil
            row.syncedFingerprint = nil
            row.file = nil
        }
    }

    // MARK: - Journal

    private func beginJournal(
        _ change: DestinationChangeModel,
        row: DestinationItemRecord,
        runID: SyncRunID,
        preWriteVersion: String?,
        pushedFingerprint: Data?
    ) throws -> DestinationJournalRecord {
        let entry = DestinationJournalRecord(
            runID: runID,
            destinationID: change.destinationID,
            itemID: row.id,
            operation: change.operation == .delete ? .delete : .set,
            itemName: row.syncedName ?? row.name,
            preWriteVersion: preWriteVersion,
            pushedFingerprint: pushedFingerprint,
            startedAt: clock.now
        )
        return try session.database.write { tx in try store.appendJournal(entry, in: tx) }
    }

    private func finishJournal(_ entry: inout DestinationJournalRecord, state: DestinationJournalRecord.State, error: String?) throws {
        entry.state = state
        entry.errorCode = error
        entry.finishedAt = clock.now
        let finished = entry
        try session.database.write { tx in try store.updateJournal(finished, in: tx) }
    }

    /// Writes left `in_flight` or indeterminate by an interrupted run are settled by the listing:
    /// a set whose item now has another version than before the write counts as done with the
    /// fingerprint journaled before it (never the row's current one, which may have been edited
    /// since), a delete whose item is gone as done; the rest as failed.
    private func reconcileJournal(_ destination: DestinationModel, listed: [RemoteDestinationItemModel]) throws {
        let byName = Self.usableByName(listed)
        let now = clock.now
        try session.database.write { tx in
            for var entry in try store.fetchUnresolvedJournal(destinationID: destination.id, in: tx) {
                let item = byName[GitHubNameValidator.foldKey(entry.itemName)]
                let row = try entry.itemID.flatMap { try store.fetchItemRecord(id: $0, in: tx) }
                switch entry.operation {
                case .set, .recover:
                    if let item, item.version != entry.preWriteVersion, var row, let pushed = entry.pushedFingerprint {
                        row.syncedName = row.name
                        row.syncedKind = item.kind
                        row.syncedFingerprint = pushed
                        row.remoteVersion = item.version
                        row.forcePush = false
                        try store.updateItem(row, in: tx)
                        entry.state = .reconciled
                    } else {
                        entry.state = .failed
                    }
                case .delete:
                    if item == nil {
                        if let row, row.isDeleted { try store.deleteItem(id: row.id, in: tx) }
                        entry.state = .reconciled
                    } else {
                        entry.state = .failed
                    }
                }
                entry.finishedAt = now
                try store.updateJournal(entry, in: tx)
            }
            try store.pruneJournal(now: now, in: tx)
        }
    }

    // MARK: - Row bookkeeping

    /// Releases every hold of `packageIDs`, in both item tables (one transaction; a no-op for the
    /// rows the GitHub run already released). Returns the held row ids of `review` it released;
    /// empty when the write failed, so nothing held runs.
    private func releaseHolds(_ packageIDs: Set<SharePackageID>, in review: DestinationReviewModel) -> Set<ConfigItemID> {
        let ids = review.sections.flatMap { $0.held.filter { packageIDs.contains($0.packageID) }.map(\.change.itemID) }
        guard !ids.isEmpty else { return [] }
        do {
            try session.database.write { tx in
                try ShareHoldStore(database: session.database).clearShareHold(packageIDs: packageIDs, in: tx)
            }
        } catch {
            Self.log.error("Releasing \(ids.count, privacy: .public) held destination rows failed")
            return []
        }
        return Set(ids)
    }

    private func pendingRows(_ destinationID: DestinationID) throws -> [DestinationItemRecord] {
        try session.database.read { tx in
            try store.fetchItemRecords(destinationID: destinationID, in: tx).filter { $0.pendingOperation != nil }
        }
    }

    private func change(for row: DestinationItemRecord, in destination: DestinationModel, remote: RemoteDestinationItemModel?) -> DestinationChangeModel {
        let name = row.isDeleted ? (row.syncedName ?? row.name) : row.name
        return DestinationChangeModel(
            destinationID: destination.id,
            itemID: row.id,
            name: name,
            remoteName: remote?.remoteName ?? DestinationRules.remoteName(for: name, provider: destination.provider),
            kind: row.kind,
            operation: row.pendingOperation ?? .update
        )
    }

    private struct OpenedValue {
        let value: SecretBytes
        let fingerprint: Data
    }

    /// The row's value and its fingerprint as stored now. Nil when the value is missing.
    private func openValue(_ row: DestinationItemRecord) throws -> OpenedValue? {
        try session.read { keys, tx in
            guard let current = try store.fetchItemRecord(id: row.id, in: tx), let fingerprint = current.valueFingerprint,
                  let value = try DestinationFieldCipher.openValue(of: current, keys: keys)
            else { return nil }
            return OpenedValue(value: value, fingerprint: fingerprint)
        }
    }

    private func recordPush(
        _ id: ConfigItemID,
        pushedFingerprint: Data,
        kind: ConfigKind,
        written: RemoteWriteResultModel,
        existing: RemoteDestinationItemModel?
    ) throws {
        let now = clock.now
        try session.database.write { tx in
            guard var row = try store.fetchItemRecord(id: id, in: tx) else { return }
            row.syncedName = row.isDeleted ? (row.syncedName ?? row.name) : row.name
            row.syncedKind = kind
            row.syncedFingerprint = pushedFingerprint
            row.preWriteVersion = existing?.version
            row.remoteVersion = written.version ?? row.remoteVersion
            row.forcePush = false
            row.verifyState = .pending
            row.updatedAt = now
            try store.updateItem(row, in: tx)
        }
    }

    private func recordConfirmation(_ id: ConfigItemID, listed: RemoteDestinationItemModel?) throws {
        try session.database.write { tx in
            guard var row = try store.fetchItemRecord(id: id, in: tx) else { return }
            if let listed {
                row.verifyState = .verified
                row.remoteVersion = listed.version
            } else {
                row.verifyState = .pending
                row.forcePush = row.valueCiphertext != nil
            }
            try store.updateItem(row, in: tx)
        }
    }

    private func finalizeDeletion(_ id: ConfigItemID) throws {
        try session.database.write { tx in
            guard let row = try store.fetchItemRecord(id: id, in: tx), row.isDeleted else { return }
            try store.deleteItem(id: id, in: tx)
        }
    }

    private func touchRefreshed(_ id: DestinationID) throws {
        let now = clock.now
        try session.database.write { tx in
            guard var destination = try store.fetchDestination(id: id, in: tx) else { return }
            destination.lastRefreshedAt = now
            try store.updateDestination(destination, in: tx)
        }
    }

    // MARK: - Remote access

    private func loadDestination(_ id: DestinationID) throws(DestinationSyncError) -> DestinationModel {
        let destination: DestinationModel?
        do throws(ConfigRepositoryError) {
            destination = try repository.destination(id)
        } catch {
            throw .config(error)
        }
        guard let destination else { throw .config(.destinationNotFound) }
        return destination
    }

    private func remote(for destination: DestinationModel) async throws(DestinationSyncError) -> any DestinationRemoting {
        do throws(DestinationError) {
            return try await remotes.remote(for: destination)
        } catch {
            throw .remote(error)
        }
    }

    private func listing(_ remote: any DestinationRemoting, of destination: DestinationModel) async throws(DestinationSyncError) -> [RemoteDestinationItemModel] {
        do throws(DestinationError) {
            return try await remote.list()
        } catch {
            throw .remote(error)
        }
    }

    /// Usable remote items by FX Vault's name fold key (the first one wins).
    private static func usableByName(_ items: [RemoteDestinationItemModel]) -> [String: RemoteDestinationItemModel] {
        var byName: [String: RemoteDestinationItemModel] = [:]
        for item in items where item.unusableReason == nil {
            guard let name = item.name else { continue }
            let key = GitHubNameValidator.foldKey(name)
            if byName[key] == nil { byName[key] = item }
        }
        return byName
    }

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "destination-sync")
}
