import Foundation
import GRDB
import VaultCore

/// `sync_journal.state` (D28).
public enum SyncJournalState: String, Sendable, Hashable, Codable, CaseIterable {
    /// Written right before the gh command starts.
    case inFlight = "in_flight"
    case succeeded
    case failed
    /// Not attempted (a dependency failed, or the run stopped).
    case skipped
    /// The command may or may not have reached GitHub (timeout, 5xx, network, crash).
    case indeterminate
    /// An `in_flight` or `indeterminate` row resolved by a later re-list.
    case reconciled
}

/// One `sync_journal` row (§6 `v4_sync_journal`, D28): one gh command of a sync run.
/// Names only, never values.
public struct SyncJournalRecord: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "sync_journal"

    /// Autoincrement row id; nil until inserted.
    public var id: Int64?
    public var runID: SyncRunID
    public var accountLogin: String
    /// Set to NULL when the repository row is deleted.
    public var repositoryID: RepoID?
    /// `ConfigChangeModel.kind` raw value.
    public var op: String
    /// The gh command id, for example `secret.set`, `variable.delete`, `repo.create`,
    /// `api.env.put`.
    public var command: String
    /// True when the command writes to GitHub (counts toward the throttle, D12).
    public var isWrite: Bool
    /// Display label of the scope, for example `Repository` or an environment name.
    public var scopeLabel: String
    /// Stable key of the target within the run (repo, scope and folded name).
    public var targetKey: String
    public var itemName: String?
    public var state: SyncJournalState
    /// gh's exit code, once it exited.
    public var exitCode: Int?
    /// The `GHStderrClassifier` result.
    public var errorCode: String?
    public var startedAt: Date
    /// GitHub's `updatedAt` listed right before the write (verification baseline, §7.3).
    public var preWriteUpdatedAt: Date?
    public var finishedAt: Date?

    public init(
        id: Int64? = nil,
        runID: SyncRunID,
        accountLogin: String,
        repositoryID: RepoID?,
        op: String,
        command: String,
        isWrite: Bool,
        scopeLabel: String,
        targetKey: String,
        itemName: String? = nil,
        state: SyncJournalState = .inFlight,
        exitCode: Int? = nil,
        errorCode: String? = nil,
        startedAt: Date,
        preWriteUpdatedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.accountLogin = accountLogin
        self.repositoryID = repositoryID
        self.op = op
        self.command = command
        self.isWrite = isWrite
        self.scopeLabel = scopeLabel
        self.targetKey = targetKey
        self.itemName = itemName
        self.state = state
        self.exitCode = exitCode
        self.errorCode = errorCode
        self.startedAt = startedAt
        self.preWriteUpdatedAt = preWriteUpdatedAt
        self.finishedAt = finishedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case runID = "run_id"
        case accountLogin = "account_login"
        case repositoryID = "repository_id"
        case op
        case command
        case isWrite = "is_write"
        case scopeLabel = "scope_label"
        case targetKey = "target_key"
        case itemName = "item_name"
        case state
        case exitCode = "exit_code"
        case errorCode = "error_code"
        case startedAt = "started_at"
        case preWriteUpdatedAt = "pre_write_updated_at"
        case finishedAt = "finished_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}

/// One `imported_share_packages` row (§6 `v6_sharing`): replay detection for share imports
/// (§9.5).
public struct ImportedSharePackageRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "imported_share_packages"

    public var packageID: SharePackageID
    /// The package's `createdAt` as the sender stated it (unverified).
    public var createdAt: Date
    public var importedAt: Date
    /// The sender's display name as the package stated it (unverified).
    public var senderName: String?

    public init(packageID: SharePackageID, createdAt: Date, importedAt: Date, senderName: String?) {
        self.packageID = packageID
        self.createdAt = createdAt
        self.importedAt = importedAt
        self.senderName = senderName
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case packageID = "package_id"
        case createdAt = "created_at"
        case importedAt = "imported_at"
        case senderName = "sender_name"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}
