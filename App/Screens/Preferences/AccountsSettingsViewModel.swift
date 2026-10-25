import Foundation
import GitHubKit
import Observation
import VaultCore
import VaultData

/// Preferences › Accounts (§10, M2): every gh account with its token state and scopes (OK, or
/// missing with copyable fix commands, or unknown), the gh path and version, the SSH alias picker
/// from `~/.ssh/config`, **Test** ("Authenticates as <login>") and **Re-check**. Since v0.3.1
/// also the accounts gh lists that FX Vault cannot use (with why), and a note when the user's
/// shell exports `GH_TOKEN` or `GITHUB_TOKEN`. Since v0.3.2 the GitHub aliases no account uses,
/// with how to log their account in to gh. Since 1.0 (B4) each account's organizations with
/// their access, and the commands that add `admin:org`.
///
/// Needs the vault unlocked (the tab shows "Unlock FX Vault…" otherwise); a lock clears it.
@Observable
final class AccountsSettingsViewModel: LockObserving {
    private(set) var accounts: [GHAccountSummaryModel] = []
    private(set) var installation: GHInstallationModel?
    private(set) var sshHosts: [SSHHostEntryModel] = []
    /// Scope fix commands by account id (only for accounts with missing scopes).
    private(set) var fixCommands: [String: [String]] = [:]
    /// Each logged-in account's organizations with their access, by account id. Absent when the
    /// account's organizations could not be read.
    private(set) var organizations: [String: [OrgAccessModel]] = [:]
    /// The commands that add `admin:org`, by account id (only when an organization needs it).
    private(set) var adminOrgCommands: [String: [String]] = [:]
    /// The last **Test** result by account id.
    private(set) var testResults: [String: SSHAliasTestResultModel] = [:]
    /// Accounts with a Test, Re-check or alias change in flight.
    private(set) var busyAccountIDs: Set<String> = []
    private(set) var isLoading = false
    private(set) var error: ErrorPresentationModel?
    /// The command copied last (shows "Copied").
    private(set) var copiedCommand: String?
    /// Accounts gh lists on github.com that FX Vault cannot use, with the reason.
    private(set) var unusableAccounts: [GHUnusableAccountModel] = []
    /// The token variables the user's shell exports (names only): gh in Terminal uses them,
    /// FX Vault never does.
    private(set) var tokenVariables: [ShellVariableName] = []

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

    /// Reads the SSH hosts, the gh installation (detecting it if needed) and the accounts with
    /// their scopes. The hosts come first: they do not need gh.
    func load() async {
        guard isAvailable, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        error = nil
        sshHosts = github.sshHostEntries()
        do {
            tokenVariables = try await github.shellEnvironment().exportedTokenVariables
        } catch {
            tokenVariables = []
        }
        if let current = await github.installation {
            installation = current
        } else {
            let preferences = app.container.preferences
            do {
                installation = try await github.detectGH(
                    overridePath: preferences.ghPathOverride,
                    trustedBinary: preferences.trustedGHBinary
                )
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
        unusableAccounts = await github.unusableAccounts
        await loadFixCommands()
        await loadOrganizations()
    }

    /// **Check Again**: reads gh's accounts again (an account just logged in from Terminal) and
    /// has the main window list them too.
    func checkAgain() async {
        await load()
        app.accountsDidChange()
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

    private func loadOrganizations() async {
        var loaded: [String: [OrgAccessModel]] = [:]
        var commands: [String: [String]] = [:]
        for account in accounts where account.status?.state == .ok {
            // A failing account keeps its token chip as the explanation; its organizations stay hidden.
            guard let access = try? await github.organizationAccess(accountLogin: account.account.login) else { continue }
            loaded[account.id] = access
            if access.contains(where: { $0.status == .needsAdminOrgScope }) {
                commands[account.id] = await github.adminOrgFixCommands(for: account.account.login)
            }
        }
        organizations = loaded
        adminOrgCommands = commands
    }

    // MARK: - Actions

    /// **Re-check**: forgets the account's cached token and reads gh's accounts again.
    func recheck(_ account: GHAccountSummaryModel) async {
        await perform(account) {
            accounts = try await github.recheck(login: account.account.login)
            await loadFixCommands()
            await loadOrganizations()
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

    /// GitHub aliases that no account uses, typically the key of an account that is not logged in
    /// to gh: FX Vault lists only gh's accounts, so such an alias was only a choice in the other
    /// accounts' menus, with nothing saying why its account was missing.
    var unmappedAliases: [SSHHostEntryModel] {
        let mapped = Set(accounts.compactMap(\.account.sshHostAlias))
        return aliasChoices.filter { $0.looksLikeGitHub && !mapped.contains($0.alias) }
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
        unusableAccounts = []
        fixCommands = [:]
        organizations = [:]
        adminOrgCommands = [:]
        testResults = [:]
        copiedCommand = nil
        error = nil
    }
}
