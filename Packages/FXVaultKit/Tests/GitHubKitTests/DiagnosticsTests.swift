import Darwin
import Foundation
import Testing
@testable import GitHubKit
import VaultCore

/// `GHDiagnosticsCollector` and `GHDiagnosticsModel` (v0.3.1): what the gh diagnostics hold, and
/// that they never hold a token or the value of a shell variable.
@Suite("gh diagnostics")
struct GHDiagnosticsTests {
    typealias Decisions = GHLocatorDecisionTests

    /// A value the shell probe captured for `GH_CONFIG_DIR`: diagnostics name the variable only.
    static let configDirValue = "/Users/user-a/.config/gh-private-marker"

    static let shell = ShellEnvironmentModel(
        path: "/opt/homebrew/bin:/usr/local/bin:/usr/bin",
        ghConfigDir: configDirValue,
        ghPath: Decisions.homebrewGH,
        setVariables: [.ghToken, .ghConfigDir],
        probeMode: .interactive,
        shellPath: "/bin/zsh"
    )

    private func collector(_ runner: FakeCommandRunner, _ files: FakeGHFileInspector) -> GHDiagnosticsCollector {
        GHDiagnosticsCollector(
            runner: runner,
            identity: ProcessIdentityModel(home: "/Users/user-a", user: "user-a", temporaryDirectory: "/tmp"),
            workingDirectory: TestValues.workingDirectory,
            fileInspector: files
        )
    }

    private func json(_ model: GHDiagnosticsModel) throws -> (text: String, object: [String: Any]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(model)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (String(decoding: data, as: UTF8.self), object)
    }

    @Test func collectsTheShellEveryCandidateAndTheAccounts() async throws {
        let files = Decisions.machine(homebrewOwner: Decisions.me)
        let runner = Decisions.runner(homebrew: "2.102.0", pkg: "2.90.0")
        runner.stub(argumentsPrefix: ["auth", "status"], with: .success(try Fixture.string("gh/auth-status-emu.json")))
        let model = await collector(runner, files).collect(shell: Self.shell, overridePath: nil, trustedBinary: nil)

        #expect(model.shell == GHDiagnosticsModel.ShellSection(
            path: "/bin/zsh",
            probeMode: .interactive,
            ghPath: Decisions.homebrewGH,
            variablesSet: ["GH_CONFIG_DIR", "GH_TOKEN"]
        ))
        #expect(model.result == "ready")
        #expect(model.chosenPath == Decisions.homebrewGH)
        let chosen = try #require(model.candidates.first)
        #expect(chosen.path == Decisions.homebrewGH)
        #expect(chosen.source == .shell)
        #expect(chosen.isChosen)
        #expect(chosen.status == "accepted")
        #expect(chosen.version == "2.102.0")
        #expect(chosen.resolvedPath == Decisions.homebrewResolved)
        let pkg = try #require(model.candidates.first { $0.path == Decisions.pkgGH })
        #expect(pkg.version == "2.90.0", "every trusted candidate's version is listed")
        #expect(!pkg.isChosen)
        #expect(model.candidates.contains { $0.status == "notFound" && $0.reason == nil })

        #expect(model.accountsChecked)
        #expect(model.accountsError == nil)
        #expect(model.accounts == [
            GHDiagnosticsModel.AccountEntry(login: "user1_acme", isActive: true, state: "ok", tokenSource: "keyring", scopes: "ok", missingScopes: []),
            GHDiagnosticsModel.AccountEntry(login: "user1-e_acme", isActive: false, state: "ok", tokenSource: "keyring", scopes: "ok", missingScopes: []),
        ])
        #expect(runner.invocations.allSatisfy { $0.environment[ProcessEnvironmentBuilder.Key.ghToken] == nil })
        #expect(!runner.invocations.contains { $0.arguments.starts(with: ["auth", "token"]) }, "no token is fetched")
    }

    @Test func aForeignOwnerIsNamedAndTheUntrustedGHNeverRuns() async throws {
        let files = Decisions.machine(homebrewOwner: Decisions.otherAdmin)
        let runner = Decisions.runner()
        let model = await collector(runner, files).collect(shell: Self.shell, overridePath: nil, trustedBinary: nil)
        #expect(model.result == "untrustedBinary")
        let chosen = try #require(model.candidates.first)
        #expect(chosen.isChosen)
        #expect(chosen.status == "rejected")
        #expect(chosen.reason == "untrustedOwner")
        #expect(chosen.ownerUID == Decisions.otherAdmin)
        #expect(chosen.ownerName == "admin-b")
        #expect(chosen.version == nil)
        #expect(!model.accountsChecked)
        #expect(!runner.invocations.contains { $0.executablePath == Decisions.homebrewResolved })
    }

    @Test func aTrustedBinaryIsListedWithItsOwner() async throws {
        let files = Decisions.machine(homebrewOwner: Decisions.otherAdmin)
        let runner = Decisions.runner()
        runner.stub(argumentsPrefix: ["auth", "status"], with: .success(#"{"hosts":{}}"#))
        let consent = GHTrustedBinaryModel(path: Decisions.homebrewGH, ownerUID: Decisions.otherAdmin)
        let model = await collector(runner, files).collect(shell: Self.shell, overridePath: nil, trustedBinary: consent)
        #expect(model.result == "ready")
        #expect(model.trustedBinary == GHDiagnosticsModel.TrustEntry(path: Decisions.homebrewGH, ownerUID: Decisions.otherAdmin, ownerName: "admin-b"))
        #expect(model.candidates.first?.isTrustedByConsent == true)
        #expect(model.accountsChecked)
        #expect(model.accounts.isEmpty)
    }

    /// Nothing in the report is a token or a variable's value, even when gh's answer contains
    /// token-shaped text in places FX Vault reads.
    @Test func neverHoldsATokenOrAVariableValue() async throws {
        let token = TestValues.token
        let files = Decisions.machine(homebrewOwner: Decisions.me)
        let runner = Decisions.runner()
        let status = """
        {"hosts":{"github.com":[
         {"state":"error","error":"HTTP 500: \(token)","active":true,"host":"github.com","login":"user-a","tokenSource":"\(token)","scopes":"repo, read:org"},
         {"state":"success","active":false,"host":"github.com","login":"user-b","tokenSource":"GH_TOKEN","scopes":"repo"},
         {"state":"success","active":false,"host":"github.com","login":"_\(token)","tokenSource":"keyring"}
        ]}}
        """
        runner.stub(argumentsPrefix: ["auth", "status"], with: .success(status))
        let model = await collector(runner, files).collect(shell: Self.shell, overridePath: nil, trustedBinary: nil)
        #expect(model.accounts.map(\.tokenSource) == ["other", "GH_TOKEN"])
        #expect(model.accounts.first?.state == "unexpected", "the error message is reduced to a code")
        #expect(model.accounts.last?.missingScopes == ["read:org"])
        #expect(model.unusableAccounts.map(\.reason) == ["invalidFirstCharacter"])

        let (text, object) = try json(model)
        #expect(!text.contains(token), "no token anywhere, not even token-shaped text gh put in a login")
        #expect(!text.contains(Self.configDirValue), "variables are named, never valued")
        #expect(text.contains("GH_CONFIG_DIR"))
        #expect(!text.contains("HTTP 500"))
        for account in model.accounts {
            #expect(!(account.tokenSource ?? "").contains(token))
        }
        // Explicit nulls, never omitted keys.
        #expect(object["overridePath"] is NSNull)
        #expect(object["trustedBinary"] is NSNull)
        #expect(object["accountsError"] is NSNull)
        #expect(Set(object.keys) == [
            "shell", "overridePath", "trustedBinary", "candidates", "chosenPath", "result",
            "accountsChecked", "accounts", "unusableAccounts", "accountsError",
        ])
        let candidate = try #require((object["candidates"] as? [[String: Any]])?.first)
        #expect(Set(candidate.keys) == [
            "path", "source", "resolvedPath", "version", "status", "reason", "ownerUID", "ownerName",
            "isTrustedByConsent", "isChosen", "versionError",
        ])
    }

    @Test func aFailedAccountListingIsACode() async throws {
        let files = Decisions.machine(homebrewOwner: Decisions.me)
        let runner = Decisions.runner()
        runner.stub(argumentsPrefix: ["auth", "status"], with: .failure(stderr: "error connecting to api.github.com"))
        let model = await collector(runner, files).collect(shell: .empty, overridePath: nil, trustedBinary: nil)
        #expect(model.result == "ready")
        #expect(model.accountsChecked)
        #expect(model.accountsError == "network")
        #expect(model.shell.probeMode == .failed)
        #expect(model.shell.path == nil)
    }
}
