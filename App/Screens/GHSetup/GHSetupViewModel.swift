import Foundation
import Observation
import VaultCore

/// What ``GHSetupScreen`` asks the user to do (§10.3).
enum GHSetupKind: Equatable {
    /// gh is missing: install it with Homebrew.
    case install
    /// gh is older than the required version: upgrade it.
    case upgrade(found: String, required: String)
    /// A gh binary failed the trust check: fix its permissions or reinstall.
    case untrusted(path: String)
    /// gh has no github.com account: log in.
    case login
    /// Detection failed for another reason.
    case failed
}

/// The gh setup screen after unlock when gh is missing, older than 2.97.0, untrusted or has no
/// accounts (§10.3, M2): copyable commands, **Check Again**, and **Not Now** to work offline.
@Observable
final class GHSetupViewModel {
    private(set) var isChecking = false
    /// The command copied last (shows "Copied").
    private(set) var copiedCommand: String?

    @ObservationIgnored private let app: AppViewModel

    /// `brew install gh` (§10.3).
    static let installCommand = "brew install gh"
    /// `brew upgrade gh` (§10.3).
    static let upgradeCommand = "brew upgrade gh"
    /// `gh auth login` (§10.3).
    static let loginCommand = "gh auth login"

    init(app: AppViewModel) {
        self.app = app
    }

    var status: GHStatusModel {
        app.ghStatus
    }

    /// Nil while checking or when gh is ready.
    var kind: GHSetupKind? {
        switch app.ghStatus {
        case .checking, .unknown, .ready: nil
        case .notInstalled: .install
        case .outdated(let found, let required): .upgrade(found: found, required: required)
        case .untrusted(let path): .untrusted(path: path)
        case .noAccounts: .login
        case .failed: .failed
        }
    }

    /// The commands to show, in the order to run them.
    var commands: [String] {
        switch kind {
        case .install, .failed: [Self.installCommand, Self.loginCommand]
        case .upgrade: [Self.upgradeCommand]
        case .untrusted: [Self.installCommand]
        case .login: [Self.loginCommand]
        case nil: []
        }
    }

    func copy(_ command: String) {
        app.container.clipboard.copyCommand(command)
        copiedCommand = command
    }

    /// **Check Again**: runs detection again; the screen goes away once gh is ready.
    func checkAgain() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        copiedCommand = nil
        await app.refreshGHStatus()
    }

    /// **Not Now**: open the vault without gh (no listing, import, sync or drift).
    func notNow() {
        app.deferGHSetup()
    }
}
