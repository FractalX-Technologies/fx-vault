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

/// Why a gh candidate was not trusted (§5.10 gh binary trust). The raw value is a stable,
/// value-free code (diagnostics).
public enum GHBinaryRejection: String, Sendable, Hashable, Codable {
    case notFound
    case notRegularFile
    case notExecutable
    /// The file is world-writable, or group-writable by a group other than `wheel` / `admin`.
    case writableFile
    /// The file's folder (or the symlink's folder) is world-writable, or group-writable by a
    /// group other than `wheel` / `admin`.
    case writableDirectory
    /// The file or a folder is owned by someone other than the user or root (and the user has
    /// not trusted that owner for this path).
    case untrustedOwner
}

/// Finds a trusted gh ≥ 2.97.0 (tasks/todo.md §5.10, §8 A1; D5; v0.3.1).
///
/// Candidates, in order: the user's override (then the only one); the gh the user's shell finds
/// (`command -v gh` from the shell probe, the gh Terminal runs); Homebrew (`/opt/homebrew/bin`,
/// `/usr/local/bin`); each directory of the shell PATH; MacPorts (`/opt/local/bin`); Nix
/// (`~/.nix-profile/bin`, `/run/current-system/sw/bin`, `/nix/var/nix/profiles/default/bin`);
/// and `~/.local/bin`.
///
/// **The first candidate that exists decides.** It is used when it passes the trust check and
/// the version floor; otherwise detection fails with its reason. FX Vault never falls back to
/// another gh behind it, so it can never silently run a different (older) gh than Terminal:
/// the other candidates appear only in the report (diagnostics).
///
/// A candidate is rejected when the file or its folder (and, for a symlink, the link's folder)
/// is world-writable, is group-writable by a group other than `wheel` or `admin`, or is owned
/// by someone other than the user or root. Homebrew creates `/opt/homebrew/bin` as `rwxrwxr-x`
/// with group `admin`; members of `admin` can already become root, so that group write grants
/// no extra power and is accepted (a deviation from the plan's literal "group-writable" rule).
/// When the only problem is that one other (non-root) user owns them, typically because another
/// administrator installed Homebrew, the user can trust that owner for that path
/// (``GHTrustedBinaryModel``): the candidate is then accepted while the owner is unchanged and
/// nothing is writable by others.
public struct GHLocator: Sendable {
    private let runner: any CommandRunning
    private let identity: ProcessIdentityModel
    private let workingDirectory: URL
    private let fileInspector: any GHFileInspecting

    static let executableName = "gh"
    static let homebrewDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    /// A path component of every file Homebrew installs (`…/Cellar/gh/<version>/bin/gh`).
    static let homebrewCellarComponent = "/Cellar/"

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
    private static let otherWritable = mode_t(S_IWOTH)
    private static let groupWritable = mode_t(S_IWGRP)

    public init(
        runner: any CommandRunning,
        identity: ProcessIdentityModel,
        workingDirectory: URL,
        fileInspector: any GHFileInspecting = SystemGHFileInspector()
    ) {
        self.runner = runner
        self.identity = identity
        self.workingDirectory = workingDirectory
        self.fileInspector = fileInspector
    }

    /// Resolves gh and checks its version.
    ///
    /// - With an `overridePath`, only that path is considered: missing → ``GHError/notInstalled``,
    ///   untrusted → ``GHError/untrustedBinary(path:)``.
    /// - Otherwise the first candidate that exists decides (see the type documentation).
    /// - Below the floor → ``GHError/versionTooOld(found:required:)``.
    public func locate(
        overridePath: String?,
        shell: ShellEnvironmentModel,
        trustedBinary: GHTrustedBinaryModel? = nil
    ) async throws(GHError) -> GHInstallationModel {
        try await inspect(overridePath: overridePath, shell: shell, trustedBinary: trustedBinary).outcome.get()
    }

    /// Every candidate with its trust result, the one that decided, and the outcome. Only the
    /// decisive candidate's `gh --version` runs, unless `checksEveryVersion` (diagnostics) asks
    /// for every trusted one. An untrusted binary is never run.
    public func inspect(
        overridePath: String?,
        shell: ShellEnvironmentModel,
        trustedBinary: GHTrustedBinaryModel? = nil,
        checksEveryVersion: Bool = false
    ) async -> GHLocatorReportModel {
        var reports = Self.candidates(overridePath: overridePath, shell: shell, home: identity.home).map {
            Self.evaluate(path: $0.path, source: $0.source, consent: trustedBinary, inspector: fileInspector)
        }
        guard let decisiveIndex = reports.firstIndex(where: \.isFound) else {
            return GHLocatorReportModel(candidates: reports, decisiveIndex: nil, outcome: .failure(.notInstalled))
        }
        let outcome: Result<GHInstallationModel, GHError>
        if reports[decisiveIndex].isAccepted {
            let checked = await check(reports[decisiveIndex], shell: shell)
            reports[decisiveIndex] = checked.report
            outcome = checked.outcome
        } else {
            outcome = .failure(.untrustedBinary(path: reports[decisiveIndex].path))
        }
        if checksEveryVersion {
            for index in reports.indices where index != decisiveIndex && reports[index].isAccepted {
                reports[index] = await check(reports[index], shell: shell).report
            }
        }
        return GHLocatorReportModel(candidates: reports, decisiveIndex: decisiveIndex, outcome: outcome)
    }

    /// A1: `gh --version` (no `GH_TOKEN`).
    public static func versionCommand() throws(GHError) -> GHCommand {
        try GHCommand(operation: .version, arguments: ["--version"], logTemplate: "--version")
    }

    /// Runs `gh --version` on an accepted candidate.
    private func check(_ candidate: GHCandidateReportModel, shell: ShellEnvironmentModel) async
        -> (report: GHCandidateReportModel, outcome: Result<GHInstallationModel, GHError>)
    {
        var report = candidate
        guard let resolved = candidate.resolvedPath else { return (report, .failure(.notInstalled)) }
        do {
            let version = try await version(of: resolved, shell: shell)
            report.version = version
            guard version.isSupported else {
                return (report, .failure(.versionTooOld(found: version, required: .minimum)))
            }
            return (report, .success(GHInstallationModel(path: candidate.path, resolvedPath: resolved, version: version)))
        } catch {
            report.versionFailure = error
            return (report, .failure(error))
        }
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

    /// The candidates in search order, without duplicates (the first source of a path wins).
    public static func candidates(overridePath: String?, shell: ShellEnvironmentModel, home: String)
        -> [(path: String, source: GHCandidateSource)]
    {
        if let overridePath, !overridePath.isEmpty {
            return [(expandingTilde(overridePath, home: home), .override)]
        }
        var entries: [(path: String, source: GHCandidateSource)] = []
        if let ghPath = shell.ghPath {
            entries.append((ghPath, .shell))
        }
        let shellDirectories = shell.path.map { path in
            path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        } ?? []
        let directories = homebrewDirectories.map { ($0, GHCandidateSource.homebrew) }
            + shellDirectories.map { ($0, GHCandidateSource.shellPATH) }
            + fallbackDirectories(home: home).map { ($0, GHCandidateSource.fallback) }
        for (directory, source) in directories {
            entries.append(((directory as NSString).appendingPathComponent(executableName), source))
        }
        var seen: Set<String> = []
        return entries.filter { seen.insert($0.path).inserted }
    }

    /// The candidate paths in search order without a shell gh, without duplicates.
    public static func candidatePaths(shellPATH: String?, home: String) -> [String] {
        candidates(overridePath: nil, shell: ShellEnvironmentModel(path: shellPATH), home: home).map(\.path)
    }

    /// Checks one candidate on the real file system. On success returns the resolved
    /// (symlink-free) path.
    public static func trust(of path: String) -> Result<String, GHBinaryRejection> {
        let report = evaluate(path: path, source: .override, consent: nil, inspector: SystemGHFileInspector())
        if let rejection = report.rejection {
            return .failure(rejection)
        }
        return .success(report.resolvedPath ?? path)
    }

    /// The trust check of one candidate (§5.10). Writable by others always rejects; files and
    /// folders owned by another (non-root) user reject unless `consent` names this exact path
    /// and that owner. Never runs anything.
    public static func evaluate(
        path: String,
        source: GHCandidateSource,
        consent: GHTrustedBinaryModel?,
        inspector: any GHFileInspecting
    ) -> GHCandidateReportModel {
        func rejected(_ reason: GHBinaryRejection, resolved: String?, owner: GHBinaryOwnerModel? = nil) -> GHCandidateReportModel {
            GHCandidateReportModel(path: path, source: source, resolvedPath: resolved, rejection: reason, foreignOwner: owner)
        }
        guard inspector.exists(atPath: path),
              let resolved = inspector.resolvedPath(path),
              let file = inspector.status(atPath: resolved)
        else { return rejected(.notFound, resolved: nil) }
        guard file.isRegularFile else { return rejected(.notRegularFile, resolved: resolved) }
        guard inspector.isExecutable(atPath: resolved) else { return rejected(.notExecutable, resolved: resolved) }

        var folders = [(resolved as NSString).deletingLastPathComponent]
        let linkFolder = (path as NSString).deletingLastPathComponent
        if linkFolder != folders[0] {
            folders.append(linkFolder)
        }
        var folderStatuses: [GHFileStatusModel] = []
        for folder in folders {
            guard let status = inspector.status(atPath: folder) else { return rejected(.notFound, resolved: nil) }
            folderStatuses.append(status)
        }
        let privileged = inspector.privilegedGroupIDs
        if isWritableByOthers(file, privilegedGroups: privileged) {
            return rejected(.writableFile, resolved: resolved)
        }
        if folderStatuses.contains(where: { isWritableByOthers($0, privilegedGroups: privileged) }) {
            return rejected(.writableDirectory, resolved: resolved)
        }

        let trustedOwners: Set<uid_t> = [inspector.currentUserID, rootUID]
        let foreignOwners = Set(([file] + folderStatuses).map(\.ownerID)).subtracting(trustedOwners)
        guard let foreignUID = foreignOwners.first else {
            return GHCandidateReportModel(path: path, source: source, resolvedPath: resolved, rejection: nil)
        }
        guard foreignOwners.count == 1 else {
            // Several other users: nothing a single consent could name.
            return rejected(.untrustedOwner, resolved: resolved)
        }
        let owner = GHBinaryOwnerModel(uid: foreignUID, name: inspector.userName(for: foreignUID))
        if let consent, consent.path == path, consent.ownerUID == foreignUID {
            return GHCandidateReportModel(
                path: path,
                source: source,
                resolvedPath: resolved,
                rejection: nil,
                foreignOwner: owner,
                isTrustedByConsent: true
            )
        }
        return rejected(.untrustedOwner, resolved: resolved, owner: owner)
    }

    /// World-writable, or group-writable by a group whose members cannot already become root.
    static func isWritableByOthers(_ status: GHFileStatusModel, privilegedGroups: Set<gid_t>) -> Bool {
        if status.mode & otherWritable != 0 { return true }
        guard status.mode & groupWritable != 0 else { return false }
        return !privilegedGroups.contains(status.groupID)
    }

    private static func expandingTilde(_ path: String, home: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return home + path.dropFirst()
    }
}

extension GHBinaryRejection: Error {}
