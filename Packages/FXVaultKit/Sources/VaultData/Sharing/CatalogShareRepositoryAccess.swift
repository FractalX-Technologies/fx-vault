import Foundation
import GitHubKit
import SharingKit
import VaultCore

/// ``ShareRepositoryAccessChecking`` through this Mac's gh accounts (B2): a repository counts as
/// importable when one logged-in account can see it, and is imported through that account
/// (the §9.5 one-click import, for every ⇣ repository of a bundle).
public struct CatalogShareRepositoryAccess: ShareRepositoryAccessChecking {
    private let github: GitHubEnvironmentRepository
    private let catalog: RepoCatalogRepository
    private let isGitHubReady: @Sendable () -> Bool

    /// - Parameter isGitHubReady: false while gh is missing, outdated or has no account; access
    ///   is then ``ShareRepositoryAccess/unreachable``.
    public init(
        github: GitHubEnvironmentRepository,
        catalog: RepoCatalogRepository,
        isGitHubReady: @escaping @Sendable () -> Bool
    ) {
        self.github = github
        self.catalog = catalog
        self.isGitHubReady = isGitHubReady
    }

    public func access(owner: String, name: String) async -> ShareRepositoryAccess {
        guard isGitHubReady(), let logins = try? await loggedInLogins() else { return .unreachable }
        var couldNotCheck = false
        for login in logins {
            do {
                _ = try await catalog.lookUpRepository(fullName: "\(owner)/\(name)", accountLogin: login)
                return .importable(accountLogin: login)
            } catch .github(.notFound) {
                continue
            } catch {
                couldNotCheck = true
            }
        }
        return couldNotCheck ? .unreachable : .notVisible
    }

    public func importRepository(owner: String, name: String, accountLogin: String?) async throws -> RepoID {
        guard isGitHubReady() else { throw SharingError.importBlocked(.repositoryNotImported) }
        let candidates: [String]
        if let accountLogin {
            candidates = [accountLogin]
        } else {
            candidates = try await loggedInLogins()
        }
        var lastError: (any Error)?
        for login in candidates {
            do {
                let found = try await catalog.lookUpRepository(fullName: "\(owner)/\(name)", accountLogin: login)
                return try await catalog.importRepository(found.ref, accountLogin: login).repository.id
            } catch .alreadyImported(let id) {
                return id
            } catch .github(.notFound) {
                continue
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SharingError.importBlocked(.repositoryNotImported)
    }

    private func loggedInLogins() async throws -> [String] {
        try await github.accounts().filter(\.isLoggedIn).map(\.account.login)
    }
}
