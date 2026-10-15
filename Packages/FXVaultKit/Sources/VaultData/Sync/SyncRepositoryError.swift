import Foundation
import SyncEngine
import VaultCore
import VaultStore

/// Why a ``SyncRepository`` operation failed as a whole (§4.4). Per-change failures are in the
/// `SyncResultModel` instead. Carries no names, values or localized text; the app maps each case
/// in `SyncRepositoryError+Extension.swift`.
public enum SyncRepositoryError: Error, Sendable, Hashable {
    /// SyncEngine refused (locked vault, journal failure, ...).
    case sync(SyncError)
    /// Another run is still in progress; one Sync runs at a time.
    case alreadyRunning
    /// The vault is locked or not initialized.
    case vault(VaultError)
    /// The local database failed.
    case store(StoreError)
    /// An error of an unknown type (never expected).
    case unexpected

    static func wrap(_ error: any Error) -> SyncRepositoryError {
        switch error {
        case let error as SyncRepositoryError: error
        case let error as SyncError: error == .locked ? .vault(.locked) : .sync(error)
        case let error as VaultError: .vault(error)
        case let error as StoreError: .store(error)
        default: .unexpected
        }
    }
}

/// Runs `body`, mapping whatever it throws to ``SyncRepositoryError``.
func performSync<Result>(_ body: () throws -> Result) throws(SyncRepositoryError) -> Result {
    do {
        return try body()
    } catch {
        throw SyncRepositoryError.wrap(error)
    }
}
