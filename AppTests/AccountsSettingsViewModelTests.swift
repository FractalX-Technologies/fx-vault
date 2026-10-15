import Foundation
import GitHubKit
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
}
