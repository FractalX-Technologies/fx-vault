import Foundation
import GitHubKit
import Testing
import VaultCore
@testable import FXVault

/// **Run** on the gh setup screen (tasks/todo.md B11f): only the allowlisted brew commands, only
/// with a trusted Homebrew, and the output stays on screen.
@MainActor
@Suite("Setup command Run")
struct SetupCommandRunTests {
    static let brew = "/opt/homebrew/bin/brew"

    static func homebrew() -> FakeGHFileInspector {
        let files = FakeGHFileInspector()
        files.addFolder("/opt/homebrew/bin", owner: FakeGHFileInspector.defaultUserID, mode: FakeGHFileInspector.groupWritableFolderMode)
        files.addFile(brew, owner: FakeGHFileInspector.defaultUserID)
        return files
    }

    @Test func runInstallsGHAndKeepsTheOutput() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: .notInstalled, fileInspector: Self.homebrew())
        harness.runner.stub(argumentsPrefix: ["install", "gh"], with: .success("==> Pouring gh\ngh 2.102.0 installed\n"))
        let setup = harness.app.makeGHSetupViewModel()
        await setup.runs.loadAvailability()
        #expect(setup.commands == ["brew install gh", "gh auth login"])
        #expect(setup.runs.runnable("brew install gh") == .installGH)
        #expect(setup.runs.runnable("gh auth login") == nil, "Interactive commands stay Copy-only")

        await setup.run(.installGH)
        #expect(setup.runs.lastRun == SetupRunModel(command: .installGH, lines: ["==> Pouring gh", "gh 2.102.0 installed"], failure: nil))
        #expect(harness.runner.invocations.contains { $0.executablePath == Self.brew && $0.arguments == ["install", "gh"] })
        #expect(setup.runs.running == nil)
    }

    @Test func aFailedRunShowsWhy() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: .notInstalled, fileInspector: Self.homebrew())
        harness.runner.stub(argumentsPrefix: ["install", "gh"], with: .failure(exitCode: 1, stderr: "Error: No internet"))
        let setup = harness.app.makeGHSetupViewModel()
        await setup.runs.loadAvailability()
        await setup.run(.installGH)
        #expect(setup.runs.lastRun?.lines == ["Error: No internet"])
        #expect(setup.runs.lastRun?.failure == "The command failed (exit 1).")
    }

    @Test func withoutATrustedHomebrewThereIsNoRun() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: .notInstalled, fileInspector: FakeGHFileInspector())
        let setup = harness.app.makeGHSetupViewModel()
        await setup.runs.loadAvailability()
        #expect(!setup.runs.canRun)
        #expect(setup.runs.runnable("brew install gh") == nil)
        await setup.run(.installGH)
        #expect(setup.runs.lastRun == nil)
        #expect(harness.runner.invocations.isEmpty)
    }
}
