import Foundation
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// Why a ``ConfigRepository`` operation failed (§4.4). Carries no names, values or localized
/// text; the app maps each case in `ConfigRepositoryError+Extension.swift`.
public enum ConfigRepositoryError: Error, Sendable, Hashable {
    /// No repository with that id.
    case repositoryNotFound
    /// No environment with that id in the repository.
    case environmentNotFound
    /// No item with that id.
    case itemNotFound
    /// No folder with that id (v0.7.0).
    case folderNotFound
    /// The folder already holds `limit` secrets and variables (v0.7.0).
    case folderFull(limit: Int)
    /// A subfolder can't hold subfolders, nor a folder with subfolders go into another: one
    /// level only.
    case subfolderNotAllowed
    /// No destination with that id (v0.8.0).
    case destinationNotFound
    /// No organization with that id (1.0).
    case organizationNotFound
    /// The destination already holds `limit` secrets and variables (v0.8.0).
    case destinationFull(limit: Int)
    /// The repository already has `limit` destinations (v0.8.0).
    case tooManyDestinations(limit: Int)
    /// The repository already has a destination for the same vault.
    case destinationExists
    /// The environment is deleted (a tombstone pending deletion on GitHub): revert it first.
    case environmentDeleted
    /// The viewer cannot change this scope (§2 Permissions, `RepoCapabilityModel`).
    case readOnly(RepoCapabilityModel.ReadOnlyReason)
    /// The secret's value is missing locally (§7.8): it cannot be revealed, exported or turned
    /// into a variable.
    case valueMissing
    /// A name, value, pattern or count broke a rule.
    case validation(ValidationError)
    /// A custom branch policy lists more than `limit` patterns.
    case tooManyBranchPatterns(limit: Int)
    /// The §7.1 editing rules refused the edit.
    case edit(ItemEditError)
    /// The vault is locked (or was locked during the operation) or not initialized.
    case vault(VaultError)
    /// The local database refused or failed the write.
    case store(StoreError)
    /// A value could not be encrypted.
    case encryptionFailed
    /// An error of an unknown type (never expected).
    case unexpected

    /// Maps any error thrown inside a session body to this type.
    static func wrap(_ error: any Error) -> ConfigRepositoryError {
        switch error {
        case let error as ConfigRepositoryError: error
        case let error as VaultError: .vault(error)
        case let error as StoreError: wrap(store: error)
        case let error as ItemEditError: .edit(error)
        case let error as ValidationError: .validation(error)
        case is CryptoError: .encryptionFailed
        default: .unexpected
        }
    }

    private static func wrap(store error: StoreError) -> ConfigRepositoryError {
        switch error {
        case .immutableAfterSync: .validation(.lockedAfterSync)
        case .constraintViolation(.unique): .validation(.duplicateName)
        default: .store(error)
        }
    }
}

/// Runs `body`, mapping whatever it throws to ``ConfigRepositoryError``.
func performConfig<Result>(_ body: () throws -> Result) throws(ConfigRepositoryError) -> Result {
    do {
        return try body()
    } catch {
        throw ConfigRepositoryError.wrap(error)
    }
}
