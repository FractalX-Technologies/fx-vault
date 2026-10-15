import Foundation
import GitHubKit
import VaultCore
import VaultData

/// Why the one-click import of a share's repository failed.
enum ShareRepositoryImportError: Error, Equatable, PresentableError {
    /// gh is not ready (missing, outdated, or no account).
    case gitHubUnavailable
    /// No logged-in account can see the repository (§9.5: reject).
    case noAccountHasAccess(fullName: String)

    nonisolated var errorPresentation: ErrorPresentationModel {
        switch self {
        case .gitHubUnavailable:
            ErrorPresentationModel(
                title: String(localized: "share.import.repo.noGH.title", defaultValue: "GitHub CLI needed"),
                message: String(
                    localized: "share.import.repo.noGH.message",
                    defaultValue: "Importing the repository needs the GitHub CLI with a logged-in account."
                )
            )
        case .noAccountHasAccess(let fullName):
            ErrorPresentationModel(
                title: String(localized: "share.import.repo.noAccess.title", defaultValue: "No account has access"),
                message: String(
                    localized: "share.import.repo.noAccess.message",
                    defaultValue: "None of your GitHub CLI accounts can see \(fullName), so this share can't be imported."
                )
            )
        }
    }
}

/// The one-click import of a share's repository (§9.5 preconditions): looks the repository up
/// with every logged-in gh account (B2) and imports it through the first one with access.
struct ShareRepositoryImporter {
    let github: GitHubEnvironmentRepository
    let catalog: RepoCatalogRepository
    let isGitHubReady: () -> Bool

    /// Imports `owner/name` and returns its vault id (also when it is already imported).
    func importRepository(owner: String, name: String) async throws -> RepoID {
        guard isGitHubReady() else { throw ShareRepositoryImportError.gitHubUnavailable }
        let fullName = "\(owner)/\(name)"
        let accounts = try await github.accounts().filter(\.isLoggedIn)
        var lastError: (any Error)?
        for account in accounts {
            let login = account.account.login
            do {
                let found = try await catalog.lookUpRepository(fullName: fullName, accountLogin: login)
                let result = try await catalog.importRepository(found.ref, accountLogin: login)
                return result.repository.id
            } catch .alreadyImported(let id) {
                return id
            } catch .github(.notFound) {
                continue
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        throw ShareRepositoryImportError.noAccountHasAccess(fullName: fullName)
    }
}
