import GitHubKit
import VaultData

/// What the app knows about the GitHub CLI (§10: a non-blocking status row on Welcome and on the
/// lock screen, and ``GHSetupScreen`` after unlock when gh needs attention).
enum GHStatusModel: Equatable {
    /// Detection is running.
    case checking
    /// Detection has not run (previews and tests that do not care about gh).
    case unknown
    /// gh was found, is new enough and has at least one usable github.com account.
    case ready(version: String, path: String)
    /// No gh executable was found.
    case notInstalled
    /// gh is older than the required version (D5). `path` is the gh that was checked.
    case outdated(found: String, required: String, path: String?)
    /// A gh executable exists but failed the trust check (§5.10): writable by others, not an
    /// executable file, or owned by several other users. `reason` is nil when unknown.
    case untrusted(path: String, reason: GHBinaryRejection?)
    /// The gh to use belongs to one other (non-root) user, typically because another
    /// administrator installed Homebrew. The user may trust it (v0.3.1).
    case foreignOwner(path: String, owner: GHBinaryOwnerModel, isHomebrew: Bool)
    /// gh works but no github.com account is logged in.
    case noAccounts(version: String, path: String)
    /// gh stores no github.com account and the user's shell exports `GH_TOKEN` or
    /// `GITHUB_TOKEN`: gh in Terminal uses that token (so it looks logged in) and
    /// `gh auth login` refuses to store an account; FX Vault never uses those variables (v0.3.1).
    case environmentToken(version: String, path: String, variables: [ShellVariableName])
    /// gh lists github.com accounts, but FX Vault can use none of them (v0.3.1).
    case unusableAccounts(version: String, path: String, accounts: [GHUnusableAccountModel])
    /// Detection failed for another reason (the shell probe, unreadable output).
    case failed

    /// True when FX Vault cannot reach GitHub until gh is fixed: ``GHSetupScreen`` is shown after
    /// unlock (§10.3).
    var needsSetup: Bool {
        switch self {
        case .checking, .unknown, .ready: false
        case .notInstalled, .outdated, .untrusted, .foreignOwner, .noAccounts, .environmentToken, .unusableAccounts,
             .failed:
            true
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
    /// `refreshingShell` probes the user's shell again first (**Check Again**), so a changed
    /// `~/.zshrc` is seen without a relaunch.
    func probe(refreshingShell: Bool) async -> GHStatusModel
}

/// The live probe over VaultData: `GitHubEnvironmentRepository.detectGH` (shell probe, `GHLocator`
/// trust and version checks, with the user's override and trusted gh) then `accounts()`
/// (`gh auth status`, persisted to the `accounts` table). Detection never needs the vault keys,
/// so it runs before unlock.
final class GitHubEnvironmentStatusProbe: GHStatusProbing {
    private let github: GitHubEnvironmentRepository
    private let preferences: PreferencesManager

    /// - Parameter preferences: read on every probe (Preferences › Advanced gh path override and
    ///   trusted gh).
    init(github: GitHubEnvironmentRepository, preferences: PreferencesManager) {
        self.github = github
        self.preferences = preferences
    }

    func probe(refreshingShell: Bool) async -> GHStatusModel {
        if refreshingShell {
            // Throws only when cancelled; detection then uses the cached probe.
            _ = try? await github.shellEnvironment(refresh: true)
        }
        let installation: GHInstallationModel
        do {
            installation = try await github.detectGH(
                overridePath: preferences.ghPathOverride,
                trustedBinary: preferences.trustedGHBinary
            )
        } catch {
            return Self.status(for: error, detection: await github.lastDetection)
        }
        let version = installation.version.description
        let path = installation.path
        do {
            let accounts = try await github.accounts()
            if accounts.contains(where: \.isLoggedIn) {
                return .ready(version: version, path: path)
            }
            return await withoutUsableAccounts(version: version, path: path)
        } catch .github(.notAuthenticated) {
            return await withoutUsableAccounts(version: version, path: path)
        } catch {
            // gh itself works; the accounts failure is shown in Preferences › Accounts.
            AppLog.ui.error("gh account listing failed")
            return .ready(version: version, path: path)
        }
    }

    /// No usable account: say why when FX Vault can tell (accounts it cannot use, or a token
    /// variable that makes Terminal's gh look logged in).
    private func withoutUsableAccounts(version: String, path: String) async -> GHStatusModel {
        let unusable = await github.unusableAccounts
        if !unusable.isEmpty {
            return .unusableAccounts(version: version, path: path, accounts: unusable)
        }
        let tokens: [ShellVariableName]
        do {
            tokens = try await github.shellEnvironment().exportedTokenVariables
        } catch {
            tokens = []
        }
        return tokens.isEmpty
            ? .noAccounts(version: version, path: path)
            : .environmentToken(version: version, path: path, variables: tokens)
    }

    /// The status for a detection failure; `detection` (the locator report) says which gh and why.
    static func status(for error: GitHubEnvironmentError, detection: GHLocatorReportModel?) -> GHStatusModel {
        switch error {
        case .github(.notInstalled):
            return .notInstalled
        case .github(.versionTooOld(let found, let required)):
            return .outdated(found: found.description, required: required.description, path: detection?.decisive?.path)
        case .github(.untrustedBinary(let path)):
            guard let decisive = detection?.decisive, decisive.path == path else {
                return .untrusted(path: path, reason: nil)
            }
            if decisive.canBeTrusted, let owner = decisive.foreignOwner {
                return .foreignOwner(path: path, owner: owner, isHomebrew: decisive.isHomebrew)
            }
            return .untrusted(path: path, reason: decisive.rejection)
        default:
            return .failed
        }
    }
}

/// A probe that returns a fixed status (previews and tests).
final class FixedGHStatusProbe: GHStatusProbing {
    private let status: GHStatusModel

    init(_ status: GHStatusModel) {
        self.status = status
    }

    func probe(refreshingShell: Bool) async -> GHStatusModel {
        status
    }
}
