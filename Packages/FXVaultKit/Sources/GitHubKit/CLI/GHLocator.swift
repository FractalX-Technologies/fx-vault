import Darwin
import Foundation
import VaultCore

/// The gh binary FX Vault uses (shown in Preferences › Accounts, §5.10).
public struct GHInstallationModel: Sendable, Hashable, Codable {
    /// The candidate path as found (for example `/opt/homebrew/bin/gh`).
    public let path: String
    /// The path with symlinks resolved.
    public let resolvedPath: String
    public let version: GHVersion

    public init(path: String, resolvedPath: String, version: GHVersion) {
        self.path = path
        self.resolvedPath = resolvedPath
        self.version = version
    }

    /// True when the binary moved since `previousResolvedPath` was recorded (the app warns
    /// about a change between launches).
    public func hasChanged(fromResolvedPath previousResolvedPath: String?) -> Bool {
        guard let previousResolvedPath else { return false }
        return previousResolvedPath != resolvedPath
    }
}

/// Why a gh candidate was not trusted (§5.10 gh binary trust).
public enum GHBinaryRejection: Sendable, Hashable {
    case notFound
    case notRegularFile
    case notExecutable
    /// The file is group- or world-writable.
    case writableFile
    /// The file's directory (or the symlink's directory) is group- or world-writable.
    case writableDirectory
    /// The file or a directory is owned by someone other than the user or root.
    case untrustedOwner
}

/// Finds a trusted gh ≥ 2.97.0 (tasks/todo.md §5.10, §8 A1; D5).
///
/// Candidates, in order: the user's override, Homebrew (`/opt/homebrew/bin`,
/// `/usr/local/bin`), each directory of the login-shell PATH, MacPorts (`/opt/local/bin`), Nix
/// (`~/.nix-profile/bin`, `/run/current-system/sw/bin`, `/nix/var/nix/profiles/default/bin`)
/// and `~/.local/bin`.
///
/// A candidate is rejected when the file or its directory (and, for a symlink, the link's
/// directory) is not owned by the user or root, is world-writable, or is group-writable by a
/// group other than `wheel` or `admin`. Homebrew creates `/opt/homebrew/bin` as `rwxrwxr-x`
/// with group `admin`; members of `admin` can already become root, so that group write grants
/// no extra power and is accepted (a deviation from the plan's literal "group-writable" rule).
public struct GHLocator: Sendable {
    private let runner: any CommandRunning
    private let identity: ProcessIdentityModel
    private let workingDirectory: URL

    static let executableName = "gh"
    static let homebrewDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// MacPorts, Nix and `~/.local/bin`, searched after the shell PATH.
    static func fallbackDirectories(home: String) -> [String] {
        [
            "/opt/local/bin",
            (home as NSString).appendingPathComponent(".nix-profile/bin"),
            "/run/current-system/sw/bin",
            "/nix/var/nix/profiles/default/bin",
            (home as NSString).appendingPathComponent(".local/bin"),
        ]
    }
    private static let rootUID: uid_t = 0
    private static let rootGID: gid_t = 0
    private static let adminGroupName = "admin"
    private static let otherWritable = mode_t(S_IWOTH)
    private static let groupWritable = mode_t(S_IWGRP)
    private static let fileTypeMask = mode_t(S_IFMT)
    private static let regularFileType = mode_t(S_IFREG)

    public init(runner: any CommandRunning, identity: ProcessIdentityModel, workingDirectory: URL) {
        self.runner = runner
        self.identity = identity
        self.workingDirectory = workingDirectory
    }

    /// Resolves gh and checks its version.
    ///
    /// - With an `overridePath`, only that path is considered: missing → ``GHError/notInstalled``,
    ///   untrusted → ``GHError/untrustedBinary(path:)``.
    /// - Otherwise the first existing trusted candidate wins. If candidates exist but none is
    ///   trusted, the first is reported as untrusted.
    /// - Below the floor → ``GHError/versionTooOld(found:required:)``.
    public func locate(overridePath: String?, shell: ShellEnvironmentModel) async throws(GHError)
        -> GHInstallationModel
    {
        let candidates: [String]
        if let overridePath, !overridePath.isEmpty {
            candidates = [Self.expandingTilde(overridePath, home: identity.home)]
        } else {
            candidates = Self.candidatePaths(shellPATH: shell.path, home: identity.home)
        }
        var firstUntrusted: String?
        for candidate in candidates {
            switch Self.trust(of: candidate) {
            case .success(let resolved):
                let version = try await version(of: resolved, shell: shell)
                guard version.isSupported else {
                    throw .versionTooOld(found: version, required: .minimum)
                }
                return GHInstallationModel(path: candidate, resolvedPath: resolved, version: version)
            case .failure(.notFound):
                continue
            case .failure:
                firstUntrusted = firstUntrusted ?? candidate
            }
        }
        if let firstUntrusted {
            throw .untrustedBinary(path: firstUntrusted)
        }
        throw .notInstalled
    }

    /// A1: `gh --version` (no `GH_TOKEN`).
    public static func versionCommand() throws(GHError) -> GHCommand {
        try GHCommand(operation: .version, arguments: ["--version"], logTemplate: "--version")
    }

    private func version(of path: String, shell: ShellEnvironmentModel) async throws(GHError) -> GHVersion {
        let service = GHCommandService(
            executableURL: URL(fileURLWithPath: path),
            identity: identity,
            shell: shell,
            workingDirectory: workingDirectory,
            runner: runner
        )
        let output = try await service.execute(try Self.versionCommand(), token: nil)
        defer { output.wipe() }
        let text = output.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        guard let version = GHVersion(ghVersionOutput: text) else { throw .malformedOutput }
        return version
    }

    /// The candidate paths in search order, without duplicates.
    public static func candidatePaths(shellPATH: String?, home: String) -> [String] {
        var directories = homebrewDirectories
        if let shellPATH {
            directories += shellPATH.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        }
        directories += fallbackDirectories(home: home)
        var seen: Set<String> = []
        var paths: [String] = []
        for directory in directories {
            let path = (directory as NSString).appendingPathComponent(executableName)
            if seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return paths
    }

    /// Checks one candidate. On success returns the resolved (symlink-free) path.
    public static func trust(of path: String) -> Result<String, GHBinaryRejection> {
        var linkInfo = stat()
        guard lstat(path, &linkInfo) == 0 else { return .failure(.notFound) }
        guard let resolvedPointer = realpath(path, nil) else { return .failure(.notFound) }
        let resolved = String(cString: resolvedPointer)
        free(resolvedPointer)

        var info = stat()
        guard stat(resolved, &info) == 0 else { return .failure(.notFound) }
        guard info.st_mode & fileTypeMask == regularFileType else { return .failure(.notRegularFile) }
        guard access(resolved, X_OK) == 0 else { return .failure(.notExecutable) }
        guard isTrustedOwner(info.st_uid) else { return .failure(.untrustedOwner) }
        guard !isWritableByOthers(info) else { return .failure(.writableFile) }

        var directories = [(resolved as NSString).deletingLastPathComponent]
        let linkDirectory = (path as NSString).deletingLastPathComponent
        if linkDirectory != directories[0] {
            directories.append(linkDirectory)
        }
        for directory in directories {
            var directoryInfo = stat()
            guard stat(directory, &directoryInfo) == 0 else { return .failure(.notFound) }
            guard isTrustedOwner(directoryInfo.st_uid) else { return .failure(.untrustedOwner) }
            guard !isWritableByOthers(directoryInfo) else { return .failure(.writableDirectory) }
        }
        return .success(resolved)
    }

    private static func isTrustedOwner(_ uid: uid_t) -> Bool {
        uid == getuid() || uid == rootUID
    }

    /// World-writable, or group-writable by a group whose members cannot already become root.
    static func isWritableByOthers(_ info: stat) -> Bool {
        if info.st_mode & otherWritable != 0 { return true }
        guard info.st_mode & groupWritable != 0 else { return false }
        return !privilegedGroupIDs.contains(info.st_gid)
    }

    /// `wheel` and `admin`: their members can already obtain root.
    static var privilegedGroupIDs: Set<gid_t> {
        var groups: Set<gid_t> = [rootGID]
        if let admin = getgrnam(adminGroupName) {
            groups.insert(admin.pointee.gr_gid)
        }
        return groups
    }

    private static func expandingTilde(_ path: String, home: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home + path.dropFirst()
    }
}

extension GHBinaryRejection: Error {}
