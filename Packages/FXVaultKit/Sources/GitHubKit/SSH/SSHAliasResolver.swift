import Foundation
import os
import VaultCore

/// What `ssh -T git@<alias>` proved (tasks/todo.md §8 D2).
public enum SSHAliasVerificationModel: Sendable, Hashable {
    /// GitHub greeted the key's account: `Hi <login>!`.
    case authenticated(login: String)
    /// `Permission denied`: no usable key for this alias.
    case permissionDenied
    /// `Host key verification failed`: run `ssh -T git@<alias>` once in Terminal.
    case hostKeyUnknown
    /// ssh did not finish in time.
    case timeout
    /// Anything else (including a deploy-key greeting, which names a repository).
    case failed(exitCode: Int32)
}

/// Resolves and verifies SSH aliases with `/usr/bin/ssh` (tasks/todo.md D19, §8 D1–D2).
///
/// Host-key checking is never weakened; `BatchMode=yes` prevents prompts.
public struct SSHAliasResolver: Sendable {
    private let runner: any CommandRunning
    private let identity: ProcessIdentityModel
    private let shell: ShellEnvironmentModel
    private let workingDirectory: URL

    private static let hostNameKey = "hostname"
    private static let greetingPrefix = "Hi "
    private static let greetingEnd: Character = "!"
    private static let permissionDeniedFragment = "permission denied"
    private static let hostKeyFragment = "host key verification failed"
    /// GitHub's greeting exits 1 (no shell access).
    private static let greetingExitCode: Int32 = 1

    public init(
        runner: any CommandRunning,
        identity: ProcessIdentityModel,
        shell: ShellEnvironmentModel,
        workingDirectory: URL
    ) {
        self.runner = runner
        self.identity = identity
        self.shell = shell
        self.workingDirectory = workingDirectory
    }

    /// D1 argv: `/usr/bin/ssh -G -- <alias>`.
    public static func resolveArguments(alias: String) -> [String] {
        ["-G", "--", alias]
    }

    /// D2 argv: `/usr/bin/ssh -T -o BatchMode=yes -o ConnectTimeout=10 -- git@<alias>`.
    public static func verifyArguments(alias: String) -> [String] {
        [
            "-T", "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(Timeouts.sshVerifyConnectTimeoutSeconds)",
            "--", "git@\(alias)",
        ]
    }

    /// D1: the `hostname` ssh would connect to for `alias`.
    public func resolveHostName(alias: String) async throws(GitError) -> String {
        let alias = try SSHAliasValidator.validate(alias)
        let result = try await run(arguments: Self.resolveArguments(alias: alias), timeout: Timeouts.sshVerify)
        defer { result.stdout.wipe() }
        if result.didTimeOut { throw .timeout }
        guard result.exitCode == 0 else { throw .commandFailed(exitCode: result.exitCode) }
        let output = result.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        guard let hostName = Self.parseHostName(fromSSHConfigDump: output) else { throw .malformedOutput }
        return hostName
    }

    /// D1 check: throws ``GitError/aliasNotGitHub(hostName:)`` unless the alias resolves to
    /// exactly github.com.
    public func requireGitHubAlias(_ alias: String) async throws(GitError) {
        let hostName = try await resolveHostName(alias: alias)
        guard hostName.lowercased() == GHConstants.host else {
            throw .aliasNotGitHub(hostName: hostName)
        }
    }

    /// D2: which GitHub account the alias's key authenticates as.
    public func verify(alias: String) async throws(GitError) -> SSHAliasVerificationModel {
        let alias = try SSHAliasValidator.validate(alias)
        let result = try await run(arguments: Self.verifyArguments(alias: alias), timeout: Timeouts.sshVerify)
        result.stdout.wipe()
        let stderr = StderrRedactor.redactTokenPatterns(in: result.stderr)
        let outcome = Self.classifyVerification(exitCode: result.exitCode, stderr: stderr, didTimeOut: result.didTimeOut)
        GHLog.gh.info("ssh -T git@{alias}: exit=\(result.exitCode, privacy: .public)")
        return outcome
    }

    /// Classifies D2's outcome.
    public static func classifyVerification(exitCode: Int32, stderr: String, didTimeOut: Bool)
        -> SSHAliasVerificationModel
    {
        if didTimeOut { return .timeout }
        if exitCode == greetingExitCode, let login = parseLogin(fromGreeting: stderr) {
            return .authenticated(login: login)
        }
        let lower = stderr.lowercased()
        if lower.contains(hostKeyFragment) { return .hostKeyUnknown }
        if lower.contains(permissionDeniedFragment) { return .permissionDenied }
        return .failed(exitCode: exitCode)
    }

    /// The `hostname` line of `ssh -G` output.
    public static func parseHostName(fromSSHConfigDump output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].lowercased() == hostNameKey else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The login in GitHub's greeting `Hi <login>! You've successfully authenticated…`, or nil
    /// (deploy keys greet with `Hi owner/repo!`, which is not a login).
    public static func parseLogin(fromGreeting text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let start = line.range(of: greetingPrefix) else { continue }
            let rest = line[start.upperBound...]
            guard let end = rest.firstIndex(of: greetingEnd) else { continue }
            let login = String(rest[rest.startIndex..<end])
            if OwnerLoginValidator.isValid(login) {
                return login
            }
        }
        return nil
    }

    private func run(arguments: [String], timeout: Duration) async throws(GitError) -> CommandResult {
        let spec = CommandSpec(
            executableURL: URL(fileURLWithPath: GHConstants.sshPath),
            arguments: arguments,
            environment: ProcessEnvironmentBuilder.ssh(identity: identity, shell: shell),
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
