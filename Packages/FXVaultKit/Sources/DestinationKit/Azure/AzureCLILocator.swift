import Foundation
import GitHubKit
import VaultCore

/// The `az` binary FX Vault runs (v0.8.0, tasks/todo.md R4).
public struct AzureCLIInstallationModel: Sendable, Hashable {
    /// The candidate path as found (for example `/opt/homebrew/bin/az`).
    public let path: String
    /// The path with symlinks resolved: what was checked and what runs.
    public let resolvedPath: String

    public init(path: String, resolvedPath: String) {
        self.path = path
        self.resolvedPath = resolvedPath
    }
}

/// Finds a trusted `az` (v0.8.0), with the same trust rules as GitHubKit's `GHLocator`
/// (docs/SECURITY-MODEL.md §8).
///
/// Candidates, in order: the override path (then the only one); `az` in each absolute directory
/// of the user's login-shell PATH; `/opt/homebrew/bin`; `/usr/local/bin`. **The first candidate
/// that exists decides**: it is used when it passes the trust check, otherwise the result is
/// ``DestinationError/azUntrusted(path:)``; FX Vault never falls back to another `az` behind it.
///
/// The trust check is `GHLocator.evaluate`: the resolved file and its folder (and the symlink's
/// folder) must be regular, executable, not writable by others (world, or a group other than
/// `wheel` / `admin`), and owned by the user or root. There is no consented trust for `az`.
/// Homebrew's `az` is a script that starts Homebrew's Python; only the script is checked.
public struct AzureCLILocator: Sendable {
    static let executableName = "az"
    static let fixedDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    private static let homePrefix = "~/"
    private static let home = "~"
    private static let pathSeparator: Character = ":"
    private static let absolutePrefix = "/"

    private let fileInspector: any GHFileInspecting

    public init(fileInspector: any GHFileInspecting = SystemGHFileInspector()) {
        self.fileInspector = fileInspector
    }

    /// The candidates in search order, absolute and without duplicates.
    public static func candidates(
        overridePath: String?,
        shell: ShellEnvironmentModel,
        home: String
    ) -> [(path: String, source: GHCandidateSource)] {
        if let overridePath, !overridePath.isEmpty {
            let expanded = expandingTilde(overridePath, home: home)
            return expanded.hasPrefix(absolutePrefix) ? [(expanded, .override)] : []
        }
        let shellDirectories = (shell.path ?? "").split(separator: pathSeparator).map(String.init)
        let directories = shellDirectories.map { ($0, GHCandidateSource.shellPATH) }
            + fixedDirectories.map { ($0, GHCandidateSource.homebrew) }
        var seen: Set<String> = []
        return directories
            .filter { $0.0.hasPrefix(absolutePrefix) }
            .map { ((($0.0 as NSString).appendingPathComponent(executableName)), $0.1) }
            .filter { seen.insert($0.0).inserted }
    }

    /// Finds `az`. Throws ``DestinationError/azNotInstalled`` when no candidate exists and
    /// ``DestinationError/azUntrusted(path:)`` when the decisive one fails the trust check.
    /// Runs nothing.
    public func locate(
        overridePath: String?,
        shell: ShellEnvironmentModel,
        home: String
    ) throws(DestinationError) -> AzureCLIInstallationModel {
        for candidate in Self.candidates(overridePath: overridePath, shell: shell, home: home) {
            let report = GHLocator.evaluate(path: candidate.path, source: candidate.source, consent: nil, inspector: fileInspector)
            guard report.isFound else { continue }
            guard report.isAccepted, let resolved = report.resolvedPath else {
                throw .azUntrusted(path: candidate.path)
            }
            return AzureCLIInstallationModel(path: candidate.path, resolvedPath: resolved)
        }
        throw .azNotInstalled
    }

    private static func expandingTilde(_ path: String, home: String) -> String {
        guard path == Self.home || path.hasPrefix(homePrefix) else { return path }
        return home + path.dropFirst()
    }
}
