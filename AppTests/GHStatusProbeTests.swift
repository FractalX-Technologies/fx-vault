import Darwin
import Foundation
import GitHubKit
import Testing
import VaultCore
@testable import FXVault

/// The live gh probe over `GitHubEnvironmentRepository` (scripted gh) and the setup gate.
@MainActor
@Suite("gh status probe and setup")
struct GHStatusProbeTests {
    @Test func readyWithAnAccount() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        let path = try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        await harness.app.refreshGHStatus()
        #expect(harness.app.ghStatus == .ready(version: Limits.minimumGHVersion, path: path))
        #expect(!harness.app.showsGHSetup)
        // gh auth status ran without a token, and no value was ever on argv.
        #expect(harness.runner.invocations.contains { $0.arguments.starts(with: ["auth", "status"]) })
    }

    /// The v0.3.1 root cause: two Enterprise Managed User accounts (`handle_shortcode`) made
    /// 0.3.0 show "Log in to GitHub" although gh was logged in.
    @Test func managedUserAccountsAreReady() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        let path = try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusManagedUsers)
        await harness.app.refreshGHStatus()
        #expect(harness.app.ghStatus == .ready(version: Limits.minimumGHVersion, path: path))
        #expect(!harness.app.showsGHSetup)
        let accounts = try await harness.data.github.accounts()
        #expect(Set(accounts.map(\.account.login)) == ["user1_acme", "user1-e_acme"])
    }

    @Test func outdatedGH() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        let path = try harness.installFakeGH(version: "2.90.0")
        await harness.app.refreshGHStatus()
        #expect(harness.app.ghStatus == .outdated(found: "2.90.0", required: Limits.minimumGHVersion, path: path))
        #expect(harness.app.showsGHSetup)
    }

    @Test func missingGH() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        harness.preferences.ghPathOverride = harness.sandbox.appendingPathComponent("absent/gh").path
        await harness.app.refreshGHStatus()
        #expect(harness.app.ghStatus == .notInstalled)
        #expect(harness.app.showsGHSetup)
    }

    @Test func noAccounts() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        let path = try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusNoAccounts)
        await harness.app.refreshGHStatus()
        #expect(harness.app.ghStatus == .noAccounts(version: Limits.minimumGHVersion, path: path))
        #expect(harness.app.showsGHSetup)
    }

    @Test func notLoggedInExitCodeMeansNoAccounts() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH()
        harness.runner.stub(
            argumentsPrefix: ["auth", "status"],
            with: .failure(exitCode: 4, stderr: "You are not logged into any GitHub hosts. To log in, run: gh auth login")
        )
        await harness.app.refreshGHStatus()
        guard case .noAccounts = harness.app.ghStatus else {
            Issue.record("expected noAccounts, got \(harness.app.ghStatus)")
            return
        }
    }

    // MARK: - v0.3.1: token variables, unusable accounts

    /// gh stores no account and the shell exports `GH_TOKEN`: Terminal's gh looks logged in, so
    /// the setup screen explains why and offers `env -u … gh auth login`.
    @Test func aTokenVariableWithoutAStoredAccountExplainsItself() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        let path = try harness.installFakeGH()
        harness.stubShellProbe(TestFixtures.shellProbeOutput(ghPath: nil, variables: ["GH_TOKEN", "GH_HOST"]))
        harness.stubAuthStatus(TestFixtures.authStatusNoAccounts)
        await harness.app.refreshGHStatus(refreshingShell: true)
        #expect(harness.app.ghStatus == .environmentToken(version: Limits.minimumGHVersion, path: path, variables: [.ghToken]))
        #expect(harness.app.showsGHSetup)
        let setup = harness.app.makeGHSetupViewModel()
        #expect(setup.kind == .environmentToken(variables: [.ghToken]))
        #expect(setup.commands == ["env -u GH_TOKEN -u GITHUB_TOKEN gh auth login"])

        // After the login without the variable, Check Again finds the stored account.
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        await setup.checkAgain()
        #expect(harness.app.ghStatus == .ready(version: Limits.minimumGHVersion, path: path))
    }

    @Test func aTokenVariableWithStoredAccountsIsReady() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH()
        harness.stubShellProbe(TestFixtures.shellProbeOutput(ghPath: nil, variables: ["GITHUB_TOKEN"]))
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        await harness.app.refreshGHStatus(refreshingShell: true)
        #expect(harness.app.ghStatus.isReady)
    }

    @Test func accountsFXVaultCannotUseAreNamed() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        let path = try harness.installFakeGH()
        harness.stubAuthStatus("""
        {"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"_user2","tokenSource":"keyring"}]}}
        """)
        await harness.app.refreshGHStatus()
        let unusable = GHUnusableAccountModel(displayLogin: "_user2", violation: .invalidFirstCharacter, isActive: true)
        #expect(harness.app.ghStatus == .unusableAccounts(version: Limits.minimumGHVersion, path: path, accounts: [unusable]))
        let setup = harness.app.makeGHSetupViewModel()
        #expect(setup.kind == .unusableAccounts([unusable]))
        #expect(setup.commands == ["gh auth login"])
        #expect(unusable.reasonText == NameRule.invalidFirstCharacter.localizedMessage)
    }

    @Test func checkAgainProbesTheShellAgain() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusNoAccounts)
        await harness.app.refreshGHStatus()
        let before = harness.shellProbeCount
        await harness.app.refreshGHStatus()
        #expect(harness.shellProbeCount == before, "the launch probe is cached")
        await harness.app.makeGHSetupViewModel().checkAgain()
        #expect(harness.shellProbeCount > before, "Check Again probes the shell again")
    }

    // MARK: - v0.3.1: a gh another user owns, consented trust

    static let otherAdmin: uid_t = 7001
    static let newOwner: uid_t = 7002
    static let homebrewGH = "/opt/homebrew/bin/gh"
    static let homebrewResolved = "/opt/homebrew/Cellar/gh/2.102.0/bin/gh"

    /// Homebrew installed by another administrator; the user's shell runs its gh.
    static func foreignHomebrewHarness() async throws -> (TestHarness, FakeGHFileInspector) {
        let files = FakeGHFileInspector(currentUserID: getuid())
        files.setUserName("admin-b", for: otherAdmin)
        files.setUserName("admin-c", for: newOwner)
        files.addHomebrewGH(owner: otherAdmin)
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil, fileInspector: files)
        harness.stubShellProbe(TestFixtures.shellProbeOutput(ghPath: homebrewGH))
        harness.runner.stub(
            executablePath: homebrewResolved,
            argumentsPrefix: ["--version"],
            with: .success("gh version 2.102.0 (2026-09-30)\n")
        )
        harness.stubAuthStatus(TestFixtures.authStatusManagedUsers)
        return (harness, files)
    }

    @Test func aGHOwnedByAnotherUserCanBeTrustedAndRevoked() async throws {
        let (harness, _) = try await Self.foreignHomebrewHarness()
        await harness.app.refreshGHStatus(refreshingShell: true)
        #expect(await harness.data.github.lastDetection?.decisive?.source == .shell)
        let owner = GHBinaryOwnerModel(uid: Self.otherAdmin, name: "admin-b")
        #expect(harness.app.ghStatus == .foreignOwner(path: Self.homebrewGH, owner: owner, isHomebrew: true))
        #expect(harness.app.showsGHSetup)
        #expect(!harness.runner.invocations.contains { $0.executablePath == Self.homebrewResolved }, "never run before consent")

        let setup = harness.app.makeGHSetupViewModel()
        #expect(setup.kind == .trustOwner(path: Self.homebrewGH, owner: owner, isHomebrew: true))
        #expect(setup.commands.isEmpty)
        await setup.trustOwner()
        #expect(harness.preferences.trustedGHBinary == GHTrustedBinaryModel(path: Self.homebrewGH, ownerUID: Self.otherAdmin))
        #expect(harness.app.ghStatus == .ready(version: "2.102.0", path: Self.homebrewGH))
        #expect(!harness.app.showsGHSetup)

        // Preferences › Advanced lists it with its owner; Revoke asks again.
        let preferences = PreferencesViewModel(app: harness.app)
        #expect(preferences.trustedGHBinary?.path == Self.homebrewGH)
        #expect(preferences.trustedGHOwner == owner)
        await preferences.revokeTrustedGH()
        #expect(harness.preferences.trustedGHBinary == nil)
        #expect(harness.app.ghStatus == .foreignOwner(path: Self.homebrewGH, owner: owner, isHomebrew: true))
    }

    @Test func trustEndsWhenTheOwnerChanges() async throws {
        let (harness, files) = try await Self.foreignHomebrewHarness()
        await harness.app.refreshGHStatus(refreshingShell: true)
        await harness.app.makeGHSetupViewModel().trustOwner()
        #expect(harness.app.ghStatus.isReady)

        for path in ["/opt/homebrew/bin", "/opt/homebrew/Cellar/gh/2.102.0/bin", Self.homebrewResolved] {
            files.setOwner(path, to: Self.newOwner)
        }
        await harness.app.refreshGHStatus()
        #expect(harness.app.ghStatus == .foreignOwner(
            path: Self.homebrewGH,
            owner: GHBinaryOwnerModel(uid: Self.newOwner, name: "admin-c"),
            isHomebrew: true
        ))
    }

    @Test func aWritableGHIsNeverOfferedForTrust() async throws {
        let (harness, files) = try await Self.foreignHomebrewHarness()
        files.addFolder("/opt/homebrew/bin", owner: Self.otherAdmin, group: FakeGHFileInspector.staffGroupID, mode: 0o775)
        await harness.app.refreshGHStatus(refreshingShell: true)
        #expect(harness.app.ghStatus == .untrusted(path: Self.homebrewGH, reason: .writableDirectory))
        #expect(harness.app.makeGHSetupViewModel().kind == .untrusted(path: Self.homebrewGH, reason: .writableDirectory))
    }

    /// Copy Diagnostics: the report names the gh, its owner, the variables and the accounts,
    /// never a variable's value, and it is a plain copy (not a concealed value).
    @Test func copyDiagnosticsIsPlainAndHoldsNoValues() async throws {
        let (harness, _) = try await Self.foreignHomebrewHarness()
        let configDir = "/Users/user-a/.config/gh-private-marker"
        harness.stubShellProbe(TestFixtures.shellProbeOutput(ghPath: Self.homebrewGH, variables: ["GH_CONFIG_DIR", "GH_TOKEN"], configDir: configDir))
        await harness.app.refreshGHStatus(refreshingShell: true)
        let setup = harness.app.makeGHSetupViewModel()
        await setup.copyDiagnostics()
        #expect(setup.hasCopiedDiagnostics)
        let text = try #require(harness.pasteboardString)
        #expect(text.hasPrefix(GHDiagnosticsTextRenderer.title))
        #expect(text.contains("Result: untrustedBinary"))
        #expect(text.contains("\(Self.homebrewGH) [shell]"))
        #expect(text.contains("owner admin-b, uid \(Self.otherAdmin)"))
        #expect(text.contains("Shell variables set: GH_CONFIG_DIR, GH_TOKEN"))
        #expect(text.contains("Accounts: not checked"))
        #expect(!text.contains(configDir), "variables are named, never valued")
        #expect(!harness.container.clipboard.ownsContents)

        await setup.trustOwner()
        await setup.copyDiagnostics()
        let trusted = try #require(harness.pasteboardString)
        #expect(trusted.contains("Result: ready"))
        #expect(trusted.contains("Trusted gh: \(Self.homebrewGH) (owner admin-b, uid \(Self.otherAdmin))"))
        #expect(trusted.contains("- user1_acme: state ok, active, token source keyring, scopes ok"))
        #expect(trusted.contains("- user1-e_acme: state ok, token source keyring, scopes ok"))
    }

    @Test func setupIsShownOnlyWhenUnlocked() async throws {
        let harness = try await TestHarness(vault: .locked, ghStatus: .notInstalled)
        #expect(!harness.app.showsGHSetup)
        try await harness.vaultManager.unlock(password: testPassword)
        harness.app.didUnlock()
        #expect(harness.app.showsGHSetup)
        harness.app.deferGHSetup()
        #expect(!harness.app.showsGHSetup)
    }

    // MARK: - GHSetupViewModel

    @Test(arguments: [
        (GHStatusModel.notInstalled, GHSetupKind.install, ["brew install gh", "gh auth login"]),
        (
            .outdated(found: "2.90.0", required: "2.97.0", path: "/usr/local/bin/gh"),
            .upgrade(found: "2.90.0", required: "2.97.0", path: "/usr/local/bin/gh"),
            ["brew upgrade gh"]
        ),
        (.noAccounts(version: "2.97.0", path: "/opt/homebrew/bin/gh"), .login, ["gh auth login"]),
        (
            .untrusted(path: "/usr/local/bin/gh", reason: .writableFile),
            .untrusted(path: "/usr/local/bin/gh", reason: .writableFile),
            ["brew install gh"]
        ),
        (
            .environmentToken(version: "2.97.0", path: "/opt/homebrew/bin/gh", variables: [.ghToken, .githubToken]),
            .environmentToken(variables: [.ghToken, .githubToken]),
            ["env -u GH_TOKEN -u GITHUB_TOKEN gh auth login"]
        ),
    ])
    func setupKindAndCommands(_ status: GHStatusModel, _ kind: GHSetupKind, _ commands: [String]) async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: status)
        let setup = harness.app.makeGHSetupViewModel()
        #expect(setup.kind == kind)
        #expect(setup.commands == commands)
    }

    /// `env -u` is BSD env's "remove this variable" on macOS: the command the setup screen
    /// offers really runs without the token variables.
    @Test func theEnvironmentLoginCommandRemovesTheTokenVariables() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(CommandSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["-u", "GH_TOKEN", "-u", "GITHUB_TOKEN", "/usr/bin/env"],
            environment: ["GH_TOKEN": "fixture-a", "GITHUB_TOKEN": "fixture-b", "KEEP": "1"],
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: .seconds(10)
        ))
        defer { result.stdout.wipe() }
        let output = result.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        #expect(result.isSuccess)
        #expect(output.contains("KEEP=1"))
        #expect(!output.contains("GH_TOKEN"))
        #expect(!output.contains("GITHUB_TOKEN"))
        #expect(GHSetupViewModel.environmentLoginCommand.hasPrefix("env -u GH_TOKEN -u GITHUB_TOKEN "))
    }

    @Test func copyIsPlainAndCheckAgainClearsTheGate() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        harness.preferences.ghPathOverride = harness.sandbox.appendingPathComponent("absent/gh").path
        await harness.app.refreshGHStatus()
        let setup = harness.app.makeGHSetupViewModel()
        #expect(setup.kind == .install)

        setup.copy(GHSetupViewModel.installCommand)
        #expect(harness.pasteboardString == GHSetupViewModel.installCommand)
        #expect(setup.copiedCommand == GHSetupViewModel.installCommand)
        // Commands are not concealed values: the clipboard is not cleared on lock.
        #expect(!harness.container.clipboard.ownsContents)

        try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        await setup.checkAgain()
        #expect(setup.kind == nil)
        #expect(!harness.app.showsGHSetup)
        #expect(!setup.isChecking)
    }
}
