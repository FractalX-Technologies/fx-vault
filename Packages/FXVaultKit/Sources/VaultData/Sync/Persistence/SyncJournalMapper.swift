import Foundation
import SyncEngine
import VaultCore
import VaultStore

/// Maps SyncEngine's journal models to VaultStore's `sync_journal` records and back (D28).
///
/// The two state enums are separate types with the same raw values (`in_flight`, `succeeded`,
/// …); the exhaustive switches below keep them in step at compile time.
enum SyncJournalMapper {
    static func storeState(_ state: SyncJournalOutcomeState) -> SyncJournalState {
        switch state {
        case .inFlight: .inFlight
        case .succeeded: .succeeded
        case .failed: .failed
        case .skipped: .skipped
        case .indeterminate: .indeterminate
        case .reconciled: .reconciled
        }
    }

    static func outcomeState(_ state: SyncJournalState) -> SyncJournalOutcomeState {
        switch state {
        case .inFlight: .inFlight
        case .succeeded: .succeeded
        case .failed: .failed
        case .skipped: .skipped
        case .indeterminate: .indeterminate
        case .reconciled: .reconciled
        }
    }

    /// The row to append for `entry`.
    static func record(_ entry: SyncJournalEntryModel) -> SyncJournalRecord {
        SyncJournalRecord(
            id: entry.id?.rawValue,
            runID: entry.runID,
            accountLogin: entry.accountLogin,
            repositoryID: entry.repositoryID,
            op: entry.op,
            command: entry.command.rawValue,
            isWrite: entry.isWrite,
            scopeLabel: entry.scopeLabel,
            targetKey: entry.targetKey,
            itemName: entry.itemName,
            state: storeState(entry.state),
            exitCode: entry.exitCode,
            errorCode: entry.errorCode,
            startedAt: entry.startedAt,
            preWriteUpdatedAt: entry.preWriteUpdatedAt,
            finishedAt: entry.finishedAt,
            sourceFingerprint: entry.push?.sourceFingerprint,
            pushedFingerprint: entry.push?.pushedFingerprint,
            didNormalizeValue: entry.push?.didNormalizeValue
        )
    }

    /// The model of a stored row, or nil for a command this build does not know (a row written
    /// by a newer build).
    static func model(_ record: SyncJournalRecord) -> SyncJournalEntryModel? {
        guard let command = SyncJournalCommand(rawValue: record.command) else { return nil }
        return SyncJournalEntryModel(
            id: record.id.map(SyncJournalEntryID.init),
            runID: record.runID,
            accountLogin: record.accountLogin,
            repositoryID: record.repositoryID,
            op: record.op,
            command: command,
            scopeLabel: record.scopeLabel,
            targetKey: record.targetKey,
            itemName: record.itemName,
            state: outcomeState(record.state),
            exitCode: record.exitCode,
            errorCode: record.errorCode,
            startedAt: record.startedAt,
            preWriteUpdatedAt: record.preWriteUpdatedAt,
            finishedAt: record.finishedAt,
            push: push(of: record)
        )
    }

    /// The journaled push fingerprints, or nil when the row has none (other commands, rows
    /// written before v7).
    private static func push(of record: SyncJournalRecord) -> SyncJournalPushModel? {
        guard let source = record.sourceFingerprint, let pushed = record.pushedFingerprint else { return nil }
        return SyncJournalPushModel(
            sourceFingerprint: source,
            pushedFingerprint: pushed,
            didNormalizeValue: record.didNormalizeValue ?? false
        )
    }

    static func outcome(_ outcome: SyncJournalOutcomeModel) -> SyncJournalStore.Outcome {
        SyncJournalStore.Outcome(
            state: storeState(outcome.state),
            exitCode: outcome.exitCode,
            errorCode: outcome.errorCode,
            finishedAt: outcome.finishedAt
        )
    }
}
