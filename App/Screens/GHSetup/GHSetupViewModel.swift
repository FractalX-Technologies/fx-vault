import Foundation
import GitHubKit
import Observation
import VaultCore

/// What ``GHSetupScreen`` asks the user to do (§10.3).
enum GHSetupKind: Equatable {
    /// gh is missing: install it with Homebrew.
    case install
    /// gh is older than the required version: upgrade it. `path` is the gh that was checked.
    case upgrade(found: String, required: String, path: String?)
    /// A gh binary failed the trust check: fix its permissions or reinstall.
    case untrusted(path: String, reason: GHBinaryRejection?)
    /// The gh belongs to one other (non-root) user: explain what that means and offer
    /// **Trust This gh** (v0.3.1).
    case trustOwner(path: String, owner: GHBinaryOwnerModel, isHomebrew: Bool)
    /// gh has no github.com account: log in.
    case login
    /// gh stores no account, and the user's shell exports a token variable that only gh in
    /// Terminal uses: log in without it (v0.3.1).
    case environmentToken(variables: [ShellVariableName])
    /// gh lists github.com accounts FX Vault cannot use (v0.3.1).
    case unusableAccounts([GHUnusableAccountModel])
    /// Detection failed for another reason.
    case failed
}

/// The gh setup screen after unlock when gh is missing, older than 2.97.0, untrusted or has no
/// usable account (§10.3, M2): copyable commands, **Check Again**, **Not Now** to work offline,
/// and since v0.3.1 **Trust This gh** for a gh another user owns and **Copy Diagnostics**.
@Observable
final class GHSetupViewModel {
    private(set) var isChecking = false
    private(set) var isTrusting = false
    private(set) var isCollectingDiagnostics = false
    /// The command copied last (shows "Copied").
    private(set) var copiedCommand: String?
    /// True after **Copy Diagnostics** put the report on the clipboard.
    private(set) var hasCopiedDiagnostics = false
    /// **Run** for the allowlisted commands (1.0).
    let runs: SetupCommandRunState

    @ObservationIgnored private let app: AppViewModel

    /// `brew install gh` (§10.3).
    static let installCommand = SetupCommand.installGH.displayText
    /// `brew upgrade gh` (§10.3).
    static let upgradeCommand = SetupCommand.upgradeGH.displayText
    /// `gh auth login` (§10.3).
    static let loginCommand = "gh auth login"
    /// `gh auth login` with `GH_TOKEN` and `GITHUB_TOKEN` removed for that one command (BSD
    /// `env -u`, macOS), so gh stores the account instead of refusing because a token variable
    /// is set (v0.3.1).
    static let environmentLoginCommand = "env -u GH_TOKEN -u GITHUB_TOKEN gh auth login"

    init(app: AppViewModel) {
        self.app = app
        runs = SetupCommandRunState(github: app.container.data.github)
    }

    var status: GHStatusModel {
        app.ghStatus
    }

    /// Nil while checking or when gh is ready.
    var kind: GHSetupKind? {
        switch app.ghStatus {
        case .checking, .unknown, .ready: nil
        case .notInstalled: .install
        case .outdated(let found, let required, let path): .upgrade(found: found, required: required, path: path)
        case .untrusted(let path, let reason): .untrusted(path: path, reason: reason)
        case .foreignOwner(let path, let owner, let isHomebrew): .trustOwner(path: path, owner: owner, isHomebrew: isHomebrew)
        case .noAccounts: .login
        case .environmentToken(_, _, let variables): .environmentToken(variables: variables)
        case .unusableAccounts(_, _, let accounts): .unusableAccounts(accounts)
        case .failed: .failed
        }
    }

    /// The commands to show, in the order to run them.
    var commands: [String] {
        switch kind {
        case .install, .failed: [Self.installCommand, Self.loginCommand]
        case .upgrade: [Self.upgradeCommand]
        case .untrusted: [Self.installCommand]
        case .login, .unusableAccounts: [Self.loginCommand]
        case .environmentToken: [Self.environmentLoginCommand]
        case .trustOwner, nil: []
        }
    }

    /// True while any action runs (the footer spinner).
    var isWorking: Bool {
        isChecking || isTrusting || isCollectingDiagnostics || runs.running != nil
    }

    // MARK: - Run

    /// **Run**: runs the command with Homebrew, shows its output, then checks gh again.
    func run(_ command: SetupCommand) async {
        copiedCommand = nil
        if await runs.run(command) {
            await checkAgain()
        }
    }

    func copy(_ command: String) {
        app.container.clipboard.copyCommand(command)
        copiedCommand = command
        hasCopiedDiagnostics = false
    }

    /// **Check Again**: probes the shell again, then runs detection; the screen goes away once
    /// gh is ready.
    func checkAgain() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        copiedCommand = nil
        hasCopiedDiagnostics = false
        await app.refreshGHStatus(refreshingShell: true)
    }

    /// **Trust This gh**: records this gh's path and its owner (Preferences › Advanced lists it
    /// with Revoke), then detects again.
    func trustOwner() async {
        guard case .trustOwner(let path, let owner, _) = kind, !isTrusting else { return }
        isTrusting = true
        defer { isTrusting = false }
        copiedCommand = nil
        await app.trustGHBinary(GHTrustedBinaryModel(path: path, ownerUID: owner.uid))
    }

    /// **Copy Diagnostics** (``AppViewModel/copyGHDiagnostics()``).
    func copyDiagnostics() async {
        guard !isCollectingDiagnostics else { return }
        isCollectingDiagnostics = true
        defer { isCollectingDiagnostics = false }
        await app.copyGHDiagnostics()
        copiedCommand = nil
        hasCopiedDiagnostics = true
    }

    /// **Not Now**: open the vault without gh (no listing, import, sync or drift).
    func notNow() {
        app.deferGHSetup()
    }
}
