import Foundation
import GitHubKit
import VaultCore

/// Primary key of a `sync_journal` row.
public struct SyncJournalEntryID: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let rawValue: Int64

    public init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        String(rawValue)
    }
}

/// `sync_journal.state` (tasks/todo.md §6 `v4_sync_journal`, D28). Raw values match the column.
///
/// Named apart from VaultStore's `SyncJournalState` so VaultData can import both modules
/// unqualified; VaultData maps them by raw value.
public enum SyncJournalOutcomeState: String, Sendable, Hashable, Codable, CaseIterable {
    case inFlight = "in_flight"
    case succeeded
    case failed
    case skipped
    case indeterminate
    case reconciled

    /// States launch reconciliation re-checks (§7.3 indeterminate outcomes).
    public static let unresolved: Set<SyncJournalOutcomeState> = [.inFlight, .indeterminate]
}

/// `sync_journal.command`: the gh command a row records. Value-free and stable.
public enum SyncJournalCommand: String, Sendable, Hashable, Codable, CaseIterable {
    case repoCreate = "repo.create"
    case repoView = "repo.view"
    case environmentPut = "api.env.put"
    case environmentDelete = "api.env.delete"
    case branchPolicyAdd = "api.policy.post"
    case branchPolicyDelete = "api.policy.delete"
    case secretSet = "secret.set"
    case secretDelete = "secret.delete"
    case variableSet = "variable.set"
    case variableDelete = "variable.delete"

    /// True for commands that write to GitHub (`is_write`, throttle seeding).
    public var isWrite: Bool {
        self != .repoView
    }

    /// The commands whose succeeded rows feed drift suppression (§7.7): pass their raw values to
    /// `SyncJournalStore.fetchSucceeded(repositoryID:commands:since:)` and the rows'
    /// `target_key` to ``DriftSuppressionModel/init(journalTargetKeys:)``.
    public static let deletions: Set<SyncJournalCommand> = [.secretDelete, .variableDelete, .environmentDelete]

    /// The set command of an item kind.
    static func set(_ kind: ConfigKind) -> SyncJournalCommand {
        kind == .secret ? .secretSet : .variableSet
    }

    /// The delete command of an item kind.
    static func delete(_ kind: ConfigKind) -> SyncJournalCommand {
        kind == .secret ? .secretDelete : .variableDelete
    }
}

/// One `sync_journal` row (names only, never values; D28).
public struct SyncJournalEntryModel: Sendable, Hashable, Identifiable {
    /// Nil until appended.
    public var id: SyncJournalEntryID?
    public var runID: SyncRunID
    public var accountLogin: String
    public var repositoryID: RepoID?
    /// ``ConfigChangeKind`` raw value of the change the row belongs to.
    public var op: String
    public var command: SyncJournalCommand
    /// `Repository` or the remote environment name (display only).
    public var scopeLabel: String
    /// ``ChangeTargetModel/journalKey`` of the change.
    public var targetKey: String
    /// Item name or branch pattern, when the row is about one.
    public var itemName: String?
    public var state: SyncJournalOutcomeState
    /// gh's exit code when known (0 on success).
    public var exitCode: Int?
    /// ``GHError/logCode`` (or a SyncEngine code such as `remoteChanged`).
    public var errorCode: String?
    public var startedAt: Date
    /// The secret's `updatedAt` listed right before the write (§7.3 verification baseline).
    public var preWriteUpdatedAt: Date?
    public var finishedAt: Date?
    /// What a set row pushed, as fingerprints (never values). Launch reconciliation records
    /// these, not the value as it is now. Nil for other commands and rows written before v7.
    public var push: SyncJournalPushModel?

    public init(
        id: SyncJournalEntryID? = nil,
        runID: SyncRunID,
        accountLogin: String,
        repositoryID: RepoID?,
        op: String,
        command: SyncJournalCommand,
        scopeLabel: String,
        targetKey: String,
        itemName: String? = nil,
        state: SyncJournalOutcomeState = .inFlight,
        exitCode: Int? = nil,
        errorCode: String? = nil,
        startedAt: Date,
        preWriteUpdatedAt: Date? = nil,
        finishedAt: Date? = nil,
        push: SyncJournalPushModel? = nil
    ) {
        self.id = id
        self.runID = runID
        self.accountLogin = accountLogin
        self.repositoryID = repositoryID
        self.op = op
        self.command = command
        self.scopeLabel = scopeLabel
        self.targetKey = targetKey
        self.itemName = itemName
        self.state = state
        self.exitCode = exitCode
        self.errorCode = errorCode
        self.startedAt = startedAt
        self.preWriteUpdatedAt = preWriteUpdatedAt
        self.finishedAt = finishedAt
        self.push = push
    }

    /// `is_write`.
    public var isWrite: Bool {
        command.isWrite
    }
}

/// The fingerprints of one push, journaled with its set row (`source_fp`, `pushed_fp`,
/// `did_normalize_value`). Row-bound HMACs (§5.4), never values.
public struct SyncJournalPushModel: Sendable, Hashable {
    /// `value_fp` of the value that was read for the push.
    public var sourceFingerprint: Data
    /// Fingerprint of the bytes gh received (D32-normalized).
    public var pushedFingerprint: Data
    /// Trailing CR/LF were stripped before the push.
    public var didNormalizeValue: Bool

    public init(sourceFingerprint: Data, pushedFingerprint: Data, didNormalizeValue: Bool) {
        self.sourceFingerprint = sourceFingerprint
        self.pushedFingerprint = pushedFingerprint
        self.didNormalizeValue = didNormalizeValue
    }

    /// The journaled part of a push effect.
    init(_ effect: ItemPushedEffectModel) {
        self.init(
            sourceFingerprint: effect.sourceFingerprint,
            pushedFingerprint: effect.pushedFingerprint,
            didNormalizeValue: effect.didNormalizeValue
        )
    }
}

/// The outcome written over an `in_flight` row.
public struct SyncJournalOutcomeModel: Sendable, Hashable {
    public var state: SyncJournalOutcomeState
    public var exitCode: Int?
    public var errorCode: String?
    public var finishedAt: Date

    public init(state: SyncJournalOutcomeState, exitCode: Int? = nil, errorCode: String? = nil, finishedAt: Date) {
        self.state = state
        self.exitCode = exitCode
        self.errorCode = errorCode
        self.finishedAt = finishedAt
    }

    /// Exit 0.
    static func succeeded(at date: Date) -> Self {
        SyncJournalOutcomeModel(state: .succeeded, exitCode: SyncExecutionConstants.successExitCode, finishedAt: date)
    }

    /// A classified gh failure.
    static func failed(_ error: GHError, at date: Date) -> Self {
        SyncJournalOutcomeModel(
            state: error.isIndeterminateOutcome ? .indeterminate : .failed,
            exitCode: error.exitCode,
            errorCode: error.logCode,
            finishedAt: date
        )
    }
}

/// One journal outcome inside a ``SyncCommitModel``.
public struct SyncJournalUpdateModel: Sendable, Hashable {
    public var id: SyncJournalEntryID
    public var outcome: SyncJournalOutcomeModel

    public init(id: SyncJournalEntryID, outcome: SyncJournalOutcomeModel) {
        self.id = id
        self.outcome = outcome
    }
}

/// What ``SyncPersisting/commit(_:)`` applies in **one** write transaction: journal outcomes
/// plus the row bookkeeping they imply (§7.4: "each outcome is written synchronously").
public struct SyncCommitModel: Sendable, Hashable {
    public var journal: [SyncJournalUpdateModel]
    /// Applied in order.
    public var effects: [SyncStateEffectModel]

    public init(journal: [SyncJournalUpdateModel] = [], effects: [SyncStateEffectModel] = []) {
        self.journal = journal
        self.effects = effects
    }

    public var isEmpty: Bool {
        journal.isEmpty && effects.isEmpty
    }
}

extension GHError {
    /// Outcomes after which the write may or may not have reached GitHub (§7.3).
    var isIndeterminateOutcome: Bool {
        switch self {
        case .indeterminate, .serverError, .network, .timeout: true
        default: false
        }
    }

    /// gh's exit code when the error carries one.
    var exitCode: Int? {
        if case .unexpected(let code) = self { return Int(code) }
        return nil
    }
}
