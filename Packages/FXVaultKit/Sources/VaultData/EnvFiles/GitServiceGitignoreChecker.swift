import EnvTools
import Foundation
import GitHubKit

/// EnvTools' ``GitignoreChecker`` over GitHubKit's `GitService` (§8 D4–D6): every question runs
/// `/usr/bin/git` with the hardened flags (`core.fsmonitor=`, `core.hooksPath=/dev/null`, ...),
/// so a repository's own configuration cannot run code during an export check.
public struct GitServiceGitignoreChecker: GitignoreChecker {
    private let git: GitService

    public init(git: GitService) {
        self.git = git
    }

    public func repositoryRoot(containing directory: URL) async throws -> URL? {
        try await git.repositoryRoot(containing: directory)
    }

    public func isIgnored(relativePath: String, inRepositoryAt root: URL) async throws -> Bool {
        try await git.isIgnored(relativePath: relativePath, inRepository: root)
    }

    public func isTracked(relativePath: String, inRepositoryAt root: URL) async throws -> Bool {
        try await git.isTracked(relativePath: relativePath, inRepository: root)
    }
}
