import EnvTools
import Foundation
import GitHubKit
import VaultCore
import VaultData

/// Builds the hardened `GitService` (§5.10) with the login-shell environment the gh repository
/// probed (§8 A2: PATH and `SSH_AUTH_SOCK`). `GitHubEnvironmentRepository` caches the probe; a
/// failed probe falls back to the system PATH and launchd's agent socket and is retried next time.
struct GitServiceProvider: Sendable {
    let github: GitHubEnvironmentRepository
    let runner: any CommandRunning
    let identity: ProcessIdentityModel
    let workingDirectory: URL
    let clock: any VaultClock

    func gitService() async -> GitService {
        let shell: ShellEnvironmentModel
        do {
            shell = try await github.shellEnvironment()
        } catch {
            AppLog.vault.error("Shell environment probe failed; git uses the default environment")
            shell = .empty
        }
        return GitService(
            runner: runner,
            identity: identity,
            shell: shell,
            workingDirectory: workingDirectory,
            clock: clock
        )
    }
}

/// `RepoCloning` with the probed shell environment: each clone runs through a
/// `RepoCreationRepository` built with the resolved `GitService` (cloning keeps no state in that
/// actor). ``SyncRepository`` uses it for "Clone to my Mac"; the UI's **Clone** uses it too.
struct ShellResolvingRepoCloner: RepoCloning {
    let session: VaultSession
    let github: GitHubEnvironmentRepository
    let gitProvider: GitServiceProvider
    let clock: any VaultClock
    let writePolicy: WriteCollaboratorPolicy

    func clone(_ repositoryID: RepoID, into folder: URL) async throws(RepoCreationError) -> URL {
        let creation = RepoCreationRepository(
            session: session,
            schedulers: github,
            git: await gitProvider.gitService(),
            clock: clock,
            writePolicy: writePolicy
        )
        return try await creation.clone(repositoryID, into: folder)
    }
}

/// EnvTools' `GitignoreChecker` (§8 D4–D6) over the hardened git with the probed shell
/// environment (VaultData's `GitServiceGitignoreChecker` does the work).
struct ShellResolvingGitignoreChecker: GitignoreChecker {
    let gitProvider: GitServiceProvider

    func repositoryRoot(containing directory: URL) async throws -> URL? {
        try await checker().repositoryRoot(containing: directory)
    }

    func isIgnored(relativePath: String, inRepositoryAt root: URL) async throws -> Bool {
        try await checker().isIgnored(relativePath: relativePath, inRepositoryAt: root)
    }

    func isTracked(relativePath: String, inRepositoryAt root: URL) async throws -> Bool {
        try await checker().isTracked(relativePath: relativePath, inRepositoryAt: root)
    }

    private func checker() async -> GitServiceGitignoreChecker {
        GitServiceGitignoreChecker(git: await gitProvider.gitService())
    }
}
