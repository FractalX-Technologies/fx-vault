import AppKit
import Foundation
import GitHubKit
import SwiftUI
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Preferences › Accounts over the scripted gh and a sandboxed `~/.ssh/config`.
@MainActor
@Suite("Accounts settings")
struct AccountsSettingsViewModelTests {
    static let alias = "github-personal"

    static func ready() async throws -> TestHarness {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        let ssh = harness.sandbox
            .appendingPathComponent(VaultDataComponents.OfflineSandbox.homeName, isDirectory: true)
            .appendingPathComponent(VaultDataComponents.OfflineSandbox.sshDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try Data("Host \(alias)\n  HostName github.com\n  User git\nHost build-box\n  HostName 10.0.0.2\n".utf8)
            .write(to: ssh.appendingPathComponent("config"))
        return harness
    }

    @Test func loadsInstallationAccountsScopesAndHosts() async throws {
        let harness = try await Self.ready()
        let accounts = AccountsSettingsViewModel(app: harness.app)
        #expect(accounts.isAvailable)
        await accounts.load()
        #expect(accounts.error == nil)
        #expect(accounts.installation?.version == GHVersion.minimum)
        #expect(accounts.accounts.map(\.account.login) == ["user-a", "user-b"])
        #expect(accounts.accounts[0].scopesTitle == "OK")
        #expect(accounts.accounts[1].scopesTitle == "Missing: repo, read:org")
        #expect(accounts.fixCommands["user-a"] == nil)
        #expect(accounts.fixCommands["user-b"] == [
            "gh auth switch -h github.com -u user-b",
            "gh auth refresh -h github.com -s repo,read:org",
            "gh auth switch -h github.com -u user-a",
        ])
        #expect(accounts.aliasChoices.map(\.alias) == [Self.alias, "build-box"])

        accounts.copy("gh auth refresh -h github.com -s repo,read:org")
        #expect(harness.pasteboardString == "gh auth refresh -h github.com -s repo,read:org")
    }

    @Test func recheckForgetsTheCachedToken() async throws {
        let harness = try await Self.ready()
        let accounts = AccountsSettingsViewModel(app: harness.app)
        await accounts.load()
        let cache = harness.data.github.tokenCache
        cache.store(SecretBytes(utf8: TestFixtures.token), for: "user-a")
        await accounts.recheck(try #require(accounts.accounts.first))
        #expect(cache.token(for: "user-a") == nil)
        #expect(accounts.accounts.count == 2)
    }

    @Test func mapAndTestAnSSHAlias() async throws {
        let harness = try await Self.ready()
        harness.runner.stub(argumentsPrefix: ["-G"], with: .success("user git\nhostname github.com\nport 22\n"))
        harness.runner.stub(
            argumentsPrefix: ["-T"],
            with: .failure(exitCode: 1, stderr: "Hi user-a! You've successfully authenticated, but GitHub does not provide shell access.")
        )
        let accounts = AccountsSettingsViewModel(app: harness.app)
        await accounts.load()
        let userA = try #require(accounts.accounts.first)

        await accounts.setAlias(Self.alias, for: userA)
        #expect(accounts.error == nil)
        let mapped = try #require(accounts.accounts.first)
        #expect(mapped.account.sshHostAlias == Self.alias)

        await accounts.test(mapped)
        #expect(accounts.testResults["user-a"] == .authenticatedAsAccount(login: "user-a"))
        #expect(accounts.testResults["user-a"]?.localizedMessage == "Authenticates as user-a")

        await accounts.setAlias(nil, for: mapped)
        #expect(accounts.accounts.first?.account.sshHostAlias == nil)
        #expect(accounts.testResults["user-a"] == nil)
    }

    @Test func lockClearsTheTab() async throws {
        let harness = try await Self.ready()
        let accounts = AccountsSettingsViewModel(app: harness.app)
        await accounts.load()
        harness.app.lock(trigger: .manual)
        #expect(!accounts.isAvailable)
        #expect(accounts.accounts.isEmpty)
        #expect(accounts.fixCommands.isEmpty)
    }

    /// 1.0 (B4): each account's organizations with their access, and the `admin:org` commands.
    @Test func organizationsShowTheirAccessAndTheAdminOrgCommands() async throws {
        let harness = try await Self.ready()
        harness.stubToken()
        harness.runner.stub(argumentsPrefix: ["org", "list"], with: .success("example-org\nexample-labs\n"))
        harness.runner.respond(argumentsPrefix: ["api"]) { invocation in
            invocation.arguments.last == "user/memberships/orgs/example-org"
                ? .success(#"{"state":"active","role":"admin"}"#)
                : .success(#"{"state":"active","role":"member"}"#)
        }
        let accounts = AccountsSettingsViewModel(app: harness.app)
        await accounts.load()

        #expect(accounts.organizations["user-a"] == [
            OrgAccessModel(login: "example-org", status: .needsAdminOrgScope),
            OrgAccessModel(login: "example-labs", status: .needsOrgAdmin),
        ])
        #expect(accounts.organizations["user-a"]?.first?.status.title == "Needs admin:org")
        #expect(accounts.adminOrgCommands["user-a"] == [
            "gh auth switch -h github.com -u user-a",
            "gh auth refresh -h github.com -s admin:org",
        ])

        harness.app.lock(trigger: .manual)
        #expect(accounts.organizations.isEmpty)
        #expect(accounts.adminOrgCommands.isEmpty)
    }

    @Test func anAccountWithAdminOrgIsReadyWithNoCommands() async throws {
        let harness = try await Self.ready()
        harness.stubToken()
        harness.stubAuthStatus("""
        {"hosts":{"github.com":[
         {"state":"success","active":true,"host":"github.com","login":"user-a","tokenSource":"keyring","scopes":"admin:org, repo","gitProtocol":"ssh"}
        ]}}
        """)
        harness.runner.stub(argumentsPrefix: ["org", "list"], with: .success("example-org\n"))
        harness.runner.respond(argumentsPrefix: ["api"]) { _ in .success(#"{"state":"active","role":"admin"}"#) }
        let accounts = AccountsSettingsViewModel(app: harness.app)
        await accounts.load()
        #expect(accounts.organizations["user-a"]?.map(\.status) == [.ready])
        #expect(accounts.adminOrgCommands["user-a"] == nil)
    }

    @Test func organizationsThatCantBeReadStayHiddenWithoutAnError() async throws {
        let harness = try await Self.ready()
        harness.stubToken()
        harness.runner.stub(argumentsPrefix: ["org", "list"], with: .success("example-org\n"))
        harness.runner.respond(argumentsPrefix: ["api"]) { _ in .success(#"{"state":"active","role":"admin"}"#) }
        harness.runner.replaceStub(argumentsPrefix: ["org", "list"], with: .failure(stderr: "gh: Bad credentials (HTTP 401)\n"))
        let accounts = AccountsSettingsViewModel(app: harness.app)
        await accounts.load()
        #expect(accounts.error == nil)
        #expect(accounts.organizations["user-a"] == nil)
        #expect(accounts.adminOrgCommands.isEmpty)
    }

    /// v0.3.1: Enterprise Managed User accounts are listed with their scopes and fix commands.
    @Test func managedUserAccountsAreListed() async throws {
        let harness = try await Self.ready()
        harness.stubAuthStatus(TestFixtures.authStatusManagedUsers)
        let accounts = AccountsSettingsViewModel(app: harness.app)
        await accounts.load()
        #expect(accounts.error == nil)
        #expect(Set(accounts.accounts.map(\.account.login)) == ["user1_acme", "user1-e_acme"])
        #expect(accounts.accounts.allSatisfy { $0.scopesTitle == "OK" })
        #expect(accounts.unusableAccounts.isEmpty)
        #expect(accounts.tokenVariables.isEmpty)
    }

    /// v0.3.1: the token-variable note and the accounts FX Vault cannot use.
    @Test func tokenVariableNoteAndUnusableAccounts() async throws {
        let harness = try await Self.ready()
        harness.stubShellProbe(TestFixtures.shellProbeOutput(ghPath: nil, variables: ["GITHUB_TOKEN", "GH_CONFIG_DIR"]))
        harness.stubAuthStatus("""
        {"hosts":{"github.com":[
         {"state":"success","active":true,"host":"github.com","login":"user1_acme","tokenSource":"keyring","scopes":"repo, read:org"},
         {"state":"success","active":false,"host":"github.com","login":"user3.acme","tokenSource":"keyring"}
        ]}}
        """)
        await harness.app.refreshGHStatus(refreshingShell: true)
        let accounts = AccountsSettingsViewModel(app: harness.app)
        await accounts.load()
        #expect(accounts.tokenVariables == [.githubToken])
        #expect(accounts.accounts.map(\.account.login) == ["user1_acme"])
        #expect(accounts.unusableAccounts == [
            GHUnusableAccountModel(displayLogin: "user3.acme", violation: .invalidCharacter, isActive: false),
        ])
        accounts.copy(GHSetupViewModel.environmentLoginCommand)
        #expect(harness.pasteboardString == "env -u GH_TOKEN -u GITHUB_TOKEN gh auth login")

        harness.app.lock(trigger: .manual)
        #expect(accounts.unusableAccounts.isEmpty)
    }

    @Test func missingGHIsReported() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        harness.preferences.ghPathOverride = harness.sandbox.appendingPathComponent("absent/gh").path
        let accounts = AccountsSettingsViewModel(app: harness.app)
        await accounts.load()
        #expect(accounts.installation == nil)
        #expect(accounts.error == GHError.notInstalled.presentation)
    }

    // MARK: - SSH aliases without an account (v0.3.2)

    /// The key of an account that is not logged in to gh had no place on the tab: its alias was
    /// only a choice in the other accounts' menus. GitHub aliases no account uses are listed.
    @Test func githubAliasesNoAccountUsesAreListed() async throws {
        let harness = try await Self.ready()
        let accounts = AccountsSettingsViewModel(app: harness.app)
        await accounts.load()
        #expect(accounts.unmappedAliases.map(\.alias) == [Self.alias])

        await accounts.setAlias(Self.alias, for: try #require(accounts.accounts.first))
        #expect(accounts.unmappedAliases.isEmpty)
    }

    /// The aliases do not need gh: they are listed while gh cannot be found.
    @Test func aliasesLoadWithoutGH() async throws {
        let harness = try await Self.ready()
        harness.preferences.ghPathOverride = harness.sandbox.appendingPathComponent("absent/gh").path
        let accounts = AccountsSettingsViewModel(app: harness.app)
        await accounts.load()
        #expect(accounts.error == GHError.notInstalled.presentation)
        #expect(accounts.unmappedAliases.map(\.alias) == [Self.alias])
    }

    /// **Check Again** lists an account logged in from Terminal, in the tab and in the main
    /// window's sidebar.
    @Test func checkAgainListsANewAccountInTheTabAndTheSidebar() async throws {
        let harness = try await Self.ready()
        harness.stubAuthStatus("""
        {"hosts":{"github.com":[
         {"state":"success","active":true,"host":"github.com","login":"user-a","tokenSource":"keyring","scopes":"repo, read:org","gitProtocol":"ssh"}
        ]}}
        """)
        harness.stubToken()
        harness.runner.stub(argumentsPrefix: ["org", "list"], with: .success(""))
        harness.runner.stub(argumentsPrefix: ["repo", "list"], with: .success("[]"))
        await harness.app.refreshGHStatus()
        let main = harness.app.makeMainViewModel()
        await main.sidebar.reload()
        #expect(main.sidebar.owners.map(\.login) == ["user-a"])
        let window = NSWindow(contentViewController: NSHostingController(rootView: MainScreen(viewModel: main)))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.layoutIfNeeded()

        let accounts = AccountsSettingsViewModel(app: harness.app)
        await accounts.load()
        #expect(accounts.accounts.map(\.account.login) == ["user-a"])

        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        let revision = harness.app.accountsRevision
        await accounts.checkAgain()
        #expect(accounts.accounts.map(\.account.login) == ["user-a", "user-b"])
        #expect(harness.app.accountsRevision == revision + 1)
        #expect(await TestFixtures.eventually { main.sidebar.owners.map(\.login) == ["user-a", "user-b"] })
    }
}
