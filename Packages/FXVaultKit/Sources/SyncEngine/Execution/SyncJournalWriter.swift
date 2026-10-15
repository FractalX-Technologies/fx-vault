import Foundation
import GitHubKit
import VaultCore

/// Builds and appends `sync_journal` rows for one repository of one run (D28): an `in_flight`
/// row before every gh write, then its outcome in the same commit as the row bookkeeping.
struct SyncJournalWriter: Sendable {
    let persistence: any SyncPersisting
    let clock: any VaultClock
    let runID: SyncRunID
    let accountLogin: String
    let repositoryID: RepoID

    /// Appends an `in_flight` row for `command` on behalf of `change`. A set passes its `push`
    /// fingerprints so launch reconciliation can record what was sent.
    func begin(
        _ change: ConfigChangeModel,
        command: SyncJournalCommand,
        itemName: String? = nil,
        preWriteUpdatedAt: Date? = nil,
        push: SyncJournalPushModel? = nil
    ) throws(SyncError) -> SyncJournalEntryID {
        try persistence.appendJournal(SyncJournalEntryModel(
            runID: runID,
            accountLogin: accountLogin,
            repositoryID: repositoryID,
            op: change.kind.rawValue,
            command: command,
            scopeLabel: Self.scopeLabel(of: change.operation),
            targetKey: change.target.journalKey,
            itemName: itemName ?? Self.itemName(of: change.operation),
            startedAt: clock.now,
            preWriteUpdatedAt: preWriteUpdatedAt,
            push: push
        ))
    }

    /// Commits one journal outcome with its effects.
    func finish(
        _ id: SyncJournalEntryID,
        _ outcome: SyncJournalOutcomeModel,
        effects: [SyncStateEffectModel] = []
    ) throws(SyncError) {
        try persistence.commit(SyncCommitModel(journal: [SyncJournalUpdateModel(id: id, outcome: outcome)], effects: effects))
    }

    /// `succeeded`, exit 0, now.
    func succeeded() -> SyncJournalOutcomeModel {
        .succeeded(at: clock.now)
    }

    /// A classified failure, now.
    func failed(_ error: GHError) -> SyncJournalOutcomeModel {
        .failed(error, at: clock.now)
    }

    /// A failure with a SyncEngine error code (no gh exit code).
    func failed(code: String, state: SyncJournalOutcomeState = .failed) -> SyncJournalOutcomeModel {
        SyncJournalOutcomeModel(state: state, errorCode: code, finishedAt: clock.now)
    }

    /// `reconciled`, now.
    func reconciled() -> SyncJournalOutcomeModel {
        SyncJournalOutcomeModel(state: .reconciled, finishedAt: clock.now)
    }

    static func scopeLabel(of operation: ConfigChangeOperation) -> String {
        switch operation {
        case .createRepository: SyncExecutionConstants.repositoryScopeLabel
        case .upsertEnvironment(let upsert): upsert.name
        case .renameEnvironment(let rename): rename.toName
        case .reconcileBranchPatterns(let patterns): patterns.environmentName
        case .deleteEnvironment(let delete): delete.name
        case .setItem(let set): set.environmentName ?? SyncExecutionConstants.repositoryScopeLabel
        case .deleteItem(let delete): delete.environmentName ?? SyncExecutionConstants.repositoryScopeLabel
        }
    }

    static func itemName(of operation: ConfigChangeOperation) -> String? {
        switch operation {
        case .setItem(let set): set.name
        case .deleteItem(let delete): delete.name
        default: nil
        }
    }
}
