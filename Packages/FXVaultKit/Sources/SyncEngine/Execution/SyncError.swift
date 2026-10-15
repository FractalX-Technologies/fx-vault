import Foundation
import GitHubKit
import VaultCore

/// Why a sync run (preflight, execution, reconciliation, deletion preview) could not proceed as
/// a whole (tasks/todo.md §4.4, §7.3). Per-change failures are ``SyncFailureReason`` values in the
/// ``SyncResultModel`` instead.
///
/// Carries no user-facing text (D24); the app maps each case in `SyncError+Extension.swift`.
public enum SyncError: Error, Sendable, Hashable {
    /// The vault locked (keys dropped) while the run needed a value or a fingerprint (§5.8).
    case locked
    /// ``SyncPersisting`` failed to read or write the vault database. No detail is kept: store
    /// errors may name rows.
    case persistenceFailed
    /// A local value could not be decrypted (corrupt row or AAD mismatch).
    case valueUnavailable(ConfigItemID)
    /// No gh scheduler is registered for the repository's account.
    case accountUnavailable(String)
    /// A gh read the run cannot continue without failed (for example the reconciliation re-list).
    case github(GHError)
    /// ``SyncExecutor/run(_:)`` was called a second time; an executor runs one plan.
    case alreadyRunning
    /// A stable, value-free identifier for logs.
    public var logCode: String {
        switch self {
        case .locked: "locked"
        case .persistenceFailed: "persistenceFailed"
        case .valueUnavailable: "valueUnavailable"
        case .accountUnavailable: "accountUnavailable"
        case .github(let error): "github(\(error.logCode))"
        case .alreadyRunning: "alreadyRunning"
        }
    }
}
