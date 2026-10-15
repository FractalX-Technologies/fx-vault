import Foundation
import GitHubKit
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// Why a ``RepoCreationRepository`` operation failed (§4.4). No names, values or localized
/// text; the app maps each case in `RepoCreationError+Extension.swift`.
public enum RepoCreationError: Error, Sendable, Hashable {
    /// No repository with that id in the vault.
    case repositoryNotFound
    /// `owner/name` is already in the vault (imported or staged).
    case repositoryExists(RepoID)
    /// The repository is not on GitHub yet: Sync creates it first.
    case notOnGitHub
    /// Only a repository that is still staged (not on GitHub) can be discarded.
    case alreadyOnGitHub
    /// The account has no SSH alias mapped (Preferences › Accounts, D19); cloning needs one.
    case sshAliasNotMapped
    /// No `GitService` was configured (gh and the shell environment are not detected yet).
    case gitUnavailable
    /// A name, value or count broke a rule.
    case validation(ValidationError)
    /// Staging an environment or item failed.
    case config(ConfigRepositoryError)
    case github(GHError)
    case git(GitError)
    /// The vault is locked or not initialized.
    case vault(VaultError)
    case store(StoreError)
    /// An error of an unknown type (never expected).
    case unexpected

    static func wrap(_ error: any Error) -> RepoCreationError {
        switch error {
        case let error as RepoCreationError: error
        case let error as ValidationError: .validation(error)
        case let error as ConfigRepositoryError: .config(error)
        case let error as GHError: .github(error)
        case let error as GitError: .git(error)
        case let error as VaultError: .vault(error)
        case StoreError.constraintViolation(.unique): .validation(.duplicateName)
        case let error as StoreError: .store(error)
        case let error as ItemEditError: .config(.edit(error))
        case is CryptoError: .config(.encryptionFailed)
        default: .unexpected
        }
    }
}

/// Runs `body`, mapping whatever it throws to ``RepoCreationError``.
func performCreation<Result>(_ body: () throws -> Result) throws(RepoCreationError) -> Result {
    do {
        return try body()
    } catch {
        throw RepoCreationError.wrap(error)
    }
}
