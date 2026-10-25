import EnvTools
import Foundation
import SharingKit
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// Why a ``SharingRepository`` operation failed (§4.4). No names, values or localized text; the
/// app maps each case in `SharingError+Extension.swift`. Every `.fxvault` read failure stays the
/// single `.share(.invalidFile)` ("Wrong passphrase or damaged file", §9.1).
public enum SharingError: Error, Sendable, Hashable {
    /// SharingKit refused: an unreadable file or wrong passphrase, an invalid package or a bad
    /// passphrase format.
    case share(ShareError)
    /// The re-authentication (D30) is missing, used, for another purpose, or from before a
    /// lock, unlock or key rotation.
    case authorizationInvalid
    case repositoryNotFound
    case environmentNotFound
    case itemNotFound
    /// The selection holds nothing that can be shared (only deleted rows).
    case nothingToShare
    /// The package cannot be imported (§9.5 preconditions): offer the one-click import, or
    /// explain the repository id mismatch.
    case importBlocked(ShareImportBlockReason)
    /// The replay warning (§9.5) was not confirmed.
    case replayNotConfirmed
    /// The vault changed since the preview (rows, keys, or the lock): preview again.
    case planOutdated
    /// The import draft was already applied or discarded.
    case draftClosed
    /// The file could not be read from disk.
    case fileUnreadable
    case write(SecureFileWriteError)
    /// The project share holds a production stage (``StageRisk``), which is never shared (Q13).
    case productionNotShared
    case config(ConfigRepositoryError)
    case validation(ValidationError)
    case vault(VaultError)
    case store(StoreError)
    /// An error of an unknown type (never expected).
    case unexpected

    static func wrap(_ error: any Error) -> SharingError {
        switch error {
        case let error as SharingError: error
        case let error as ShareError: .share(error)
        case let error as SecureFileWriteError: .write(error)
        case let error as ConfigRepositoryError: .config(error)
        case let error as ItemEditError: .config(.edit(error))
        case let error as ValidationError: .validation(error)
        case let error as VaultError: .vault(error)
        case StoreError.constraintViolation(.unique): .validation(.duplicateName)
        case StoreError.immutableAfterSync: .validation(.lockedAfterSync)
        case let error as StoreError: .store(error)
        case is CryptoError: .config(.encryptionFailed)
        default: .unexpected
        }
    }
}

/// Runs `body`, mapping whatever it throws to ``SharingError``.
func performSharing<Result>(_ body: () throws -> Result) throws(SharingError) -> Result {
    do {
        return try body()
    } catch {
        throw SharingError.wrap(error)
    }
}
