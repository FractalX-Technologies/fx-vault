import GitHubKit
import VaultData

/// What the app knows about the GitHub CLI (§10: a non-blocking status row on Welcome and on the
/// lock screen, and ``GHSetupScreen`` after unlock when gh needs attention).
enum GHStatusModel: Equatable {
    /// Detection is running.
    case checking
    /// Detection has not run (previews and tests that do not care about gh).
    case unknown
    /// gh was found, is new enough and has at least one github.com account.
    case ready(version: String, path: String)
    /// No gh executable was found.
    case notInstalled
    /// gh is older than the required version (D5).
    case outdated(found: String, required: String)
    /// A gh executable exists but failed the trust check (§5.10: writable by others, foreign
    /// owner).
    case untrusted(path: String)
    /// gh works but no github.com account is logged in.
    case noAccounts(version: String, path: String)
    /// Detection failed for another reason (the shell probe, unreadable output).
    case failed

    /// True when FX Vault cannot reach GitHub until gh is fixed: ``GHSetupScreen`` is shown after
    /// unlock (§10.3).
    var needsSetup: Bool {
        switch self {
        case .checking, .unknown, .ready: false
        case .notInstalled, .outdated, .untrusted, .noAccounts, .failed: true
        }
    }

    /// True when gh commands can run (repository listing, import, sync, drift).
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Detects gh (A1–A3).
protocol GHStatusProbing: AnyObject {
    func probe() async -> GHStatusModel
}

/// The live probe over VaultData: `GitHubEnvironmentRepository.detectGH` (login-shell probe,
/// `GHLocator` trust and version checks) then `accounts()` (`gh auth status`, persisted to the
/// `accounts` table). Detection never needs the vault keys, so it runs before unlock.
final class GitHubEnvironmentStatusProbe: GHStatusProbing {
    private let github: GitHubEnvironmentRepository
    private let overridePath: () -> String?

    /// - Parameter overridePath: read on every probe (Preferences › Advanced gh path override).
    init(github: GitHubEnvironmentRepository, overridePath: @escaping () -> String?) {
        self.github = github
        self.overridePath = overridePath
    }

    func probe() async -> GHStatusModel {
        let installation: GHInstallationModel
        do {
            installation = try await github.detectGH(overridePath: overridePath())
        } catch {
            return Self.status(for: error)
        }
        let version = installation.version.description
        let path = installation.path
        do {
            let accounts = try await github.accounts()
            return accounts.contains(where: \.isLoggedIn)
                ? .ready(version: version, path: path)
                : .noAccounts(version: version, path: path)
        } catch .github(.notAuthenticated) {
            return .noAccounts(version: version, path: path)
        } catch {
            // gh itself works; the accounts failure is shown in Preferences › Accounts.
            AppLog.ui.error("gh account listing failed")
            return .ready(version: version, path: path)
        }
    }

    static func status(for error: GitHubEnvironmentError) -> GHStatusModel {
        switch error {
        case .github(.notInstalled):
            .notInstalled
        case .github(.versionTooOld(let found, let required)):
            .outdated(found: found.description, required: required.description)
        case .github(.untrustedBinary(let path)):
            .untrusted(path: path)
        default:
            .failed
        }
    }
}

/// A probe that returns a fixed status (previews and tests).
final class FixedGHStatusProbe: GHStatusProbing {
    private let status: GHStatusModel

    init(_ status: GHStatusModel) {
        self.status = status
    }

    func probe() async -> GHStatusModel {
        status
    }
}
