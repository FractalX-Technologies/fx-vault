import Darwin
import Foundation
import os
import VaultCore

/// git operations with the hardened flags of tasks/todo.md §5.10 (§8 D3–D6, D18).
///
/// Every call is `/usr/bin/git -c core.fsmonitor= -c core.hooksPath=/dev/null
/// -c protocol.allow=never -c protocol.ssh.allow=always -C <dir> …` with the git environment
/// (`GIT_TERMINAL_PROMPT=0`, `GIT_CONFIG_NOSYSTEM=1`, batch-mode ssh).
public struct GitService: Sendable {
    private let runner: any CommandRunning
    private let identity: ProcessIdentityModel
    private let shell: ShellEnvironmentModel
    private let workingDirectory: URL
    private let clock: any VaultClock

    /// git exits 128 for fatal errors (network, auth, not a repository).
    static let fatalExitCode: Int32 = 128
    /// `check-ignore -q` / `ls-files --error-unmatch`: 1 means "no".
    static let negativeExitCode: Int32 = 1
    static let cloneMarker = ".fxvault-clone-"
    static let permanentCloneFragments = ["permission denied", "repository not found"]
    static let hostKeyFragment = "host key verification failed"
    static let accessDeniedFragment = "operation not permitted"

    public init(
        runner: any CommandRunning,
        identity: ProcessIdentityModel,
        shell: ShellEnvironmentModel,
        workingDirectory: URL,
        clock: any VaultClock
    ) {
        self.runner = runner
        self.identity = identity
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.clock = clock
    }

    /// The hardened prefix for a call in `directory`.
    public static func hardenedArguments(directory: URL) -> [String] {
        [
            "-c", "core.fsmonitor=",
            "-c", "core.hooksPath=/dev/null",
            "-c", "protocol.allow=never",
            "-c", "protocol.ssh.allow=always",
            "-C", directory.path,
        ]
    }

    /// The clone URL for an alias: `git@<alias>:<O>/<N>.git`.
    public static func cloneURL(alias: String, repo: GHRepoRef) -> String {
        "git@\(alias):\(repo.owner)/\(repo.name)\(RepoNameValidator.gitSuffix)"
    }

    // MARK: - D3 clone

    /// Clones `repo` through `alias` into `<folder>/<name>` (§8 D3).
    ///
    /// Clones into the sibling `<folder>/.<name>.fxvault-clone-<uuid>`, then renames it
    /// atomically (never replacing an existing directory). Exit 128 is retried
    /// `Limits.cloneRetries` times, `Timeouts.cloneRetryInterval` apart, unless stderr shows a
    /// permanent failure. On failure only the temporary directory is removed.
    public func clone(repo: GHRepoRef, alias: String, into folder: URL) async throws(GitError) -> URL {
        let alias = try SSHAliasValidator.validate(alias)
        let folder = Self.canonicalDirectory(folder)
        // `repo.name` is a validated single path segment, so this stays inside `folder`.
        let destination = folder.appendingPathComponent(repo.name, isDirectory: true)
        guard destination.deletingLastPathComponent().path == folder.path else {
            throw .destinationOutsideFolder
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw .destinationExists
        }
        let temporaryName = ".\(repo.name)\(Self.cloneMarker)\(UUID().uuidString.lowercased())"
        let temporary = folder.appendingPathComponent(temporaryName, isDirectory: true)
        let arguments = Self.hardenedArguments(directory: folder)
            + ["clone", "--", Self.cloneURL(alias: alias, repo: repo), temporaryName]

        var retriesLeft = Limits.cloneRetries
        while true {
            let result = try await run(arguments: arguments, timeout: Timeouts.gitClone)
            result.stdout.wipe()
            if result.isSuccess {
                try moveIntoPlace(temporary: temporary, destination: destination)
                GHLog.gh.info("git clone {alias}:{o}/{n}: done")
                return destination
            }
            removeTemporary(temporary, folder: folder)
            let error = Self.classifyClone(result)
            GHLog.gh.error("git clone {alias}:{o}/{n}: exit=\(result.exitCode, privacy: .public) error=\(error.logCode, privacy: .public)")
            guard result.exitCode == Self.fatalExitCode, Self.isRetryable(error), retriesLeft > 0 else {
                throw error
            }
            retriesLeft -= 1
            do {
                try await clock.sleep(for: Timeouts.cloneRetryInterval)
            } catch {
                throw .cancelled
            }
        }
    }

    /// The folder with symlinks resolved (`realpath`), or its standardized form when it does
    /// not exist (git then fails with a clear error).
    static func canonicalDirectory(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    static func classifyClone(_ result: CommandResult) -> GitError {
        if result.didTimeOut { return .timeout }
        let lower = result.stderr.lowercased()
        if lower.contains(hostKeyFragment) { return .hostKeyVerificationFailed }
        if permanentCloneFragments.contains(where: { lower.contains($0) }) { return .authenticationFailed }
        if lower.contains(accessDeniedFragment) { return .folderAccessDenied }
        return .commandFailed(exitCode: result.exitCode)
    }

    private static func isRetryable(_ error: GitError) -> Bool {
        if case .commandFailed = error { return true }
        return false
    }

    private func moveIntoPlace(temporary: URL, destination: URL) throws(GitError) {
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target -> Int32 in
                guard let source, let target else { return EINVAL }
                return renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        switch result {
        case 0:
            return
        case EEXIST, ENOTEMPTY:
            removeTemporary(temporary, folder: temporary.deletingLastPathComponent())
            throw .destinationExists
        case EPERM, EACCES:
            removeTemporary(temporary, folder: temporary.deletingLastPathComponent())
            throw .folderAccessDenied
        default:
            removeTemporary(temporary, folder: temporary.deletingLastPathComponent())
            throw .commandFailed(exitCode: result)
        }
    }

    /// Removes a temporary clone directory, and only one whose name carries the clone marker
    /// directly inside `folder`.
    private func removeTemporary(_ temporary: URL, folder: URL) {
        let name = temporary.lastPathComponent
        guard name.hasPrefix("."), name.contains(Self.cloneMarker),
              temporary.deletingLastPathComponent().path == folder.path
        else { return }
        try? FileManager.default.removeItem(at: temporary)
    }

    // MARK: - D4–D6

    /// D4: `rev-parse --show-toplevel`. Nil when `directory` is not inside a repository.
    public func repositoryRoot(containing directory: URL) async throws(GitError) -> URL? {
        let arguments = Self.hardenedArguments(directory: directory) + ["rev-parse", "--show-toplevel"]
        let result = try await run(arguments: arguments, timeout: Timeouts.ghDefault)
        defer { result.stdout.wipe() }
        if result.didTimeOut { throw .timeout }
        if result.exitCode == Self.fatalExitCode { return nil }
        guard result.exitCode == 0 else { throw .commandFailed(exitCode: result.exitCode) }
        let path = result.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
            .trimmingCharacters(in: .newlines)
        guard path.hasPrefix("/") else { throw .malformedOutput }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// D5: `check-ignore -q -- <rel>`. True when git ignores the path.
    public func isIgnored(relativePath: String, inRepository root: URL) async throws(GitError) -> Bool {
        let path = try Self.validatedRelativePath(relativePath)
        let arguments = Self.hardenedArguments(directory: root) + ["check-ignore", "-q", "--", path]
        return try await yesNo(arguments: arguments)
    }

    /// D6: `ls-files --error-unmatch -- <rel>`. True when the path is tracked ("already
    /// committed: remove it from history").
    public func isTracked(relativePath: String, inRepository root: URL) async throws(GitError) -> Bool {
        let path = try Self.validatedRelativePath(relativePath)
        let arguments = Self.hardenedArguments(directory: root) + ["ls-files", "--error-unmatch", "--", path]
        return try await yesNo(arguments: arguments)
    }

    /// A relative path whose every component is a safe path segment (no `..`, no absolute
    /// paths, no control characters).
    static func validatedRelativePath(_ path: String) throws(GitError) -> String {
        guard !path.hasPrefix("/") else { throw .invalidPath(.invalidPathSegment(.separator)) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            do {
                try PathSegmentValidator.validate(String(component))
            } catch {
                throw .invalidPath(error)
            }
        }
        return path
    }

    private func yesNo(arguments: [String]) async throws(GitError) -> Bool {
        let result = try await run(arguments: arguments, timeout: Timeouts.ghDefault)
        result.stdout.wipe()
        if result.didTimeOut { throw .timeout }
        switch result.exitCode {
        case 0: return true
        case Self.negativeExitCode: return false
        default: throw .commandFailed(exitCode: result.exitCode)
        }
    }

    private func run(arguments: [String], timeout: Duration) async throws(GitError) -> CommandResult {
        let spec = CommandSpec(
            executableURL: URL(fileURLWithPath: GHConstants.gitPath),
            arguments: arguments,
            environment: ProcessEnvironmentBuilder.git(identity: identity, shell: shell),
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        do {
            return try await runner.run(spec)
        } catch {
            throw GitError.map(error)
        }
    }
}
