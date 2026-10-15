import Foundation
import GitHubKit
import Observation
import VaultCore
import VaultData

/// Preferences › Accounts (§10, M2): every gh account with its token state and scopes (OK, or
/// missing with copyable fix commands, or unknown), the gh path and version, the SSH alias picker
/// from `~/.ssh/config`, **Test** ("Authenticates as <login>") and **Re-check**.
///
/// Needs the vault unlocked (the tab shows "Unlock FX Vault…" otherwise); a lock clears it.
@Observable
final class AccountsSettingsViewModel: LockObserving {
    private(set) var accounts: [GHAccountSummaryModel] = []
    private(set) var installation: GHInstallationModel?
    private(set) var sshHosts: [SSHHostEntryModel] = []
    /// Scope fix commands by account id (only for accounts with missing scopes).
    private(set) var fixCommands: [String: [String]] = [:]
    /// The last **Test** result by account id.
    private(set) var testResults: [String: SSHAliasTestResultModel] = [:]
    /// Accounts with a Test, Re-check or alias change in flight.
    private(set) var busyAccountIDs: Set<String> = []
    private(set) var isLoading = false
    private(set) var error: ErrorPresentationModel?
    /// The command copied last (shows "Copied").
    private(set) var copiedCommand: String?

    @ObservationIgnored private let app: AppViewModel

    init(app: AppViewModel) {
        self.app = app
        app.addLockObserver(self)
    }

    private var github: GitHubEnvironmentRepository {
        app.container.data.github
    }

    var isAvailable: Bool {
        app.phase == .unlocked
    }

    // MARK: - Loading

    /// Reads the gh installation (detecting it if needed), the accounts with their scopes and
    /// the SSH hosts.
    func load() async {
        guard isAvailable, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        error = nil
        if let current = await github.installation {
            installation = current
        } else {
            do {
                installation = try await github.detectGH(overridePath: app.container.preferences.ghPathOverride)
            } catch {
                installation = nil
                self.error = error.presentation
                return
            }
        }
        do {
            accounts = try await github.accounts()
        } catch {
            self.error = error.presentation
        }
        await loadFixCommands()
        sshHosts = github.sshHostEntries()
    }

    private func loadFixCommands() async {
        var commands: [String: [String]] = [:]
        for account in accounts {
            if case .missing = account.status?.scopes {
                commands[account.id] = await github.scopeFixCommands(for: account.account.login)
            }
        }
        fixCommands = commands
    }

    // MARK: - Actions

    /// **Re-check**: forgets the account's cached token and reads gh's accounts again.
    func recheck(_ account: GHAccountSummaryModel) async {
        await perform(account) {
            accounts = try await github.recheck(login: account.account.login)
            await loadFixCommands()
        }
    }

    /// Maps an SSH alias (nil removes the mapping); the previous Test result is cleared.
    func setAlias(_ alias: String?, for account: GHAccountSummaryModel) async {
        await perform(account) {
            let updated = try await github.mapSSHAlias(alias, to: account.account.login)
            replace(account.id, with: updated)
            testResults[account.id] = nil
        }
    }

    /// **Test**: `ssh -G` must resolve the alias to github.com, then `ssh -T` names the login.
    func test(_ account: GHAccountSummaryModel) async {
        guard let alias = account.account.sshHostAlias else { return }
        await perform(account) {
            testResults[account.id] = try await github.testSSHAlias(alias, for: account.account.login)
        }
    }

    func copy(_ command: String) {
        app.container.clipboard.copyCommand(command)
        copiedCommand = command
    }

    func isBusy(_ account: GHAccountSummaryModel) -> Bool {
        busyAccountIDs.contains(account.id)
    }

    /// The aliases offered for mapping: GitHub-looking hosts first, then the rest by name.
    var aliasChoices: [SSHHostEntryModel] {
        sshHosts.sorted { lhs, rhs in
            if lhs.looksLikeGitHub != rhs.looksLikeGitHub { return lhs.looksLikeGitHub }
            return lhs.alias.localizedCaseInsensitiveCompare(rhs.alias) == .orderedAscending
        }
    }

    private func perform(_ account: GHAccountSummaryModel, _ body: () async throws -> Void) async {
        busyAccountIDs.insert(account.id)
        defer { busyAccountIDs.remove(account.id) }
        do {
            try await body()
        } catch {
            self.error = error.presentation
        }
    }

    private func replace(_ id: String, with account: AccountModel) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index] = GHAccountSummaryModel(account: account, status: accounts[index].status)
    }

    // MARK: - LockObserving

    func vaultDidLock() {
        accounts = []
        fixCommands = [:]
        testResults = [:]
        copiedCommand = nil
        error = nil
    }
}
