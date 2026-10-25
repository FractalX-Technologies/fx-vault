import Foundation
import Testing
@testable import GitHubKit
import VaultCore

/// The allowlisted setup commands (tasks/todo.md B11f).
@Suite("SetupCommandRunner")
struct SetupCommandTests {
    static let identity = ProcessIdentityModel(home: "/Users/user-a", user: "user-a", temporaryDirectory: "/private/tmp")
    static let brew = "/opt/homebrew/bin/brew"
    static let user = FakeGHFileInspector.defaultUserID

    /// Homebrew as it installs itself: the user owns it, `bin` is group-writable by `admin`.
    static func homebrew(owner: uid_t = user, binGroup: gid_t = FakeGHFileInspector.adminGroupID) -> FakeGHFileInspector {
        let inspector = FakeGHFileInspector()
        inspector.addFolder("/opt/homebrew/bin", owner: owner, group: binGroup, mode: FakeGHFileInspector.groupWritableFolderMode)
        inspector.addFile(brew, owner: owner)
        return inspector
    }

    static func runner(_ fake: FakeCommandRunner, inspector: FakeGHFileInspector) -> SetupCommandRunner {
        SetupCommandRunner(runner: fake, inspector: inspector, identity: identity, workingDirectory: URL(fileURLWithPath: "/private/tmp"))
    }

    @Test func onlyTheAllowlistedTextsAreRunnable() {
        #expect(SetupCommand(displayText: "brew install gh") == .installGH)
        #expect(SetupCommand(displayText: "brew upgrade gh") == .upgradeGH)
        #expect(SetupCommand(displayText: "brew install azure-cli") == .installAzureCLI)
        #expect(SetupCommand(displayText: "gh auth login") == nil, "Interactive commands stay Copy-only")
        #expect(SetupCommand(displayText: "brew install gh; rm -rf ~") == nil)
    }

    @Test func homebrewEnvironmentIsExactlyTheAllowlist() {
        let environment = ProcessEnvironmentBuilder.homebrew(identity: Self.identity, prefix: "/opt/homebrew")
        #expect(Set(environment.keys) == ProcessEnvironmentBuilder.homebrewAllowedKeys)
        #expect(Set(environment.keys).isDisjoint(with: ProcessEnvironmentBuilder.forbiddenKeys))
        #expect(environment["PATH"] == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["NONINTERACTIVE"] == "1")
    }

    @Test func runsTheTrustedBrewWithFixedArguments() async throws {
        let fake = FakeCommandRunner()
        fake.stub(argumentsPrefix: ["upgrade", "gh"], with: .success("==> Upgrading gh 2.90.1 -> 2.102.0\n"))
        let output = try await Self.runner(fake, inspector: Self.homebrew()).run(.upgradeGH)
        #expect(output.exitCode == 0)
        #expect(output.lines == ["==> Upgrading gh 2.90.1 -> 2.102.0"])
        let call = try #require(fake.invocations.first)
        #expect(call.executablePath == Self.brew)
        #expect(call.arguments == ["upgrade", "gh"])
        #expect(call.timeout == Timeouts.setupCommand)
    }

    @Test func aBrewOthersCanWriteIsNeverRun() async throws {
        let fake = FakeCommandRunner()
        let staffWritable = Self.homebrew(binGroup: FakeGHFileInspector.staffGroupID)
        await #expect(throws: SetupCommandError.homebrewNotFound) {
            try await Self.runner(fake, inspector: staffWritable).run(.installGH)
        }
        await #expect(throws: SetupCommandError.homebrewNotFound) {
            try await Self.runner(fake, inspector: FakeGHFileInspector()).run(.installGH)
        }
        #expect(fake.invocations.isEmpty)
    }

    @Test func aFailureKeepsTheRedactedLastLines() async throws {
        let fake = FakeCommandRunner()
        let noisy = (1...50).map { "line \($0)" }.joined(separator: "\n")
        fake.stub(argumentsPrefix: ["install", "gh"], with: .failure(exitCode: 1, stderr: "Error: token \(TestValues.token)", stdout: noisy))
        do {
            _ = try await Self.runner(fake, inspector: Self.homebrew()).run(.installGH)
            Issue.record("A failing brew must throw")
        } catch {
            guard case .failed(let output) = error else {
                Issue.record("Unexpected \(error)")
                return
            }
            #expect(output.exitCode == 1)
            #expect(output.lines.count == SetupCommandRunner.maxOutputLines)
            #expect(output.lines.first == "line 12")
            #expect(!output.lines.joined().contains(TestValues.token))
        }
    }
}
