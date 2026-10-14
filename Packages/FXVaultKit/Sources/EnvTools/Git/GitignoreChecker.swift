import Foundation

/// The three git questions asked before a `.env` export (§8 D4–D6). VaultData implements it
/// with GitHubKit's `GitService` (hardened `/usr/bin/git` flags, §5.10); tests use fakes.
public protocol GitignoreChecker: Sendable {
    /// D4 `git -C <directory> rev-parse --show-toplevel`: the work tree root containing
    /// `directory`, or nil when `directory` is not inside a git work tree.
    func repositoryRoot(containing directory: URL) async throws -> URL?

    /// D5 `git -C <root> check-ignore -q -- <relativePath>`: true when git ignores the path.
    func isIgnored(relativePath: String, inRepositoryAt root: URL) async throws -> Bool

    /// D6 `git -C <root> ls-files --error-unmatch -- <relativePath>`: true when the path is
    /// tracked (already committed or staged).
    func isTracked(relativePath: String, inRepositoryAt root: URL) async throws -> Bool
}

/// Where an export destination stands with git.
public enum GitExposureModel: Sendable, Hashable {
    /// Not inside a git work tree.
    case outsideRepository
    /// Inside a work tree and ignored by git.
    case ignored(repositoryRoot: URL, relativePath: String)
    /// Inside a work tree and not ignored: offer to append `suggestedIgnoreLine` to
    /// `<repositoryRoot>/.gitignore` (nil when the path cannot be written as a pattern, for
    /// example a name containing a line break).
    case notIgnored(repositoryRoot: URL, relativePath: String, suggestedIgnoreLine: String?)
    /// Tracked by git: "already committed, remove it from history". Checked first, because
    /// ignore rules do not apply to tracked files.
    case tracked(repositoryRoot: URL, relativePath: String)

    /// True for ``notIgnored(repositoryRoot:relativePath:suggestedIgnoreLine:)`` and
    /// ``tracked(repositoryRoot:relativePath:)``.
    public var isExposed: Bool {
        switch self {
        case .outsideRepository, .ignored: false
        case .notIgnored, .tracked: true
        }
    }
}

/// Runs the D4–D6 checks for one export destination.
public enum GitExposureInspector {
    /// Classifies `fileURL` (which need not exist yet). Errors from `checker` are passed on;
    /// the caller shows them as "could not check git" rather than as "safe".
    public static func inspect(
        fileURL: URL,
        using checker: some GitignoreChecker
    ) async throws -> GitExposureModel {
        let directory = fileURL.deletingLastPathComponent()
        guard let root = try await checker.repositoryRoot(containing: directory) else {
            return .outsideRepository
        }
        guard let relativePath = GitignoreEditor.relativePath(of: fileURL, toRepositoryRoot: root) else {
            return .outsideRepository
        }
        if try await checker.isTracked(relativePath: relativePath, inRepositoryAt: root) {
            return .tracked(repositoryRoot: root, relativePath: relativePath)
        }
        if try await checker.isIgnored(relativePath: relativePath, inRepositoryAt: root) {
            return .ignored(repositoryRoot: root, relativePath: relativePath)
        }
        return .notIgnored(
            repositoryRoot: root,
            relativePath: relativePath,
            suggestedIgnoreLine: GitignoreEditor.ignoreLine(forRelativePath: relativePath)
        )
    }
}
