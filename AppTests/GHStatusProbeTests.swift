import Foundation
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

    @Test func outdatedGH() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH(version: "2.90.0")
        await harness.app.refreshGHStatus()
        #expect(harness.app.ghStatus == .outdated(found: "2.90.0", required: Limits.minimumGHVersion))
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
        (.outdated(found: "2.90.0", required: "2.97.0"), .upgrade(found: "2.90.0", required: "2.97.0"), ["brew upgrade gh"]),
        (.noAccounts(version: "2.97.0", path: "/opt/homebrew/bin/gh"), .login, ["gh auth login"]),
        (.untrusted(path: "/usr/local/bin/gh"), .untrusted(path: "/usr/local/bin/gh"), ["brew install gh"]),
    ])
    func setupKindAndCommands(_ status: GHStatusModel, _ kind: GHSetupKind, _ commands: [String]) async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: status)
        let setup = harness.app.makeGHSetupViewModel()
        #expect(setup.kind == kind)
        #expect(setup.commands == commands)
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
