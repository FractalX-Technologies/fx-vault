import Foundation
import GitHubKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// In-app Approve through `gh auth refresh` (1.0 B4b) over the scripted gh. The real gh never
/// runs: it would change the developer's token.
@MainActor
@Suite("GitHub approval")
struct GHApprovalTests {
    nonisolated static let code = "4F2C-91AB"
    nonisolated static let pipedOutput = "! First copy your one-time code: \(code)\nOpen this URL to continue in your web browser: https://github.com/login/device\n"
    nonisolated static let ttyOutput = "\u{1B}[0;33m!\u{1B}[0m First copy your one-time code: \u{1B}[1m\(code)\u{1B}[0m\nPress Enter to open github.com in your browser... "
    static let refresh = ["auth", "refresh"]
    static let context = GHApprovalContext(login: "user-a", ownerLogin: "example-org", scopes: [.adminOrg])
    /// user-a after the approval.
    static let approvedStatus = """
    {"hosts":{"github.com":[
     {"state":"success","active":true,"host":"github.com","login":"user-a","tokenSource":"keyring","scopes":"admin:org, gist, read:org, repo","gitProtocol":"ssh"}
    ]}}
    """

    /// After `gh auth switch -u user-b` in Terminal.
    static let userBActive = """
    {"hosts":{"github.com":[
     {"state":"success","active":false,"host":"github.com","login":"user-a","tokenSource":"keyring","scopes":"gist, read:org, repo","gitProtocol":"ssh"},
     {"state":"success","active":true,"host":"github.com","login":"user-b","tokenSource":"keyring","scopes":"gist","gitProtocol":"ssh"}
    ]}}
    """

    struct Fixture {
        let harness: TestHarness
        let recorder: ActionRecorder
        let model: GHApprovalViewModel
    }

    /// gh found, user-a active (A3 read once, as the sidebar does), and `response` for A7.
    static func fixture(
        _ response: FakeCommandRunner.Response,
        codeWait: Duration = .seconds(30)
    ) async throws -> Fixture {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        let gh = try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        try await harness.data.github.detectGH(overridePath: gh)
        _ = try await harness.data.github.accounts()
        harness.runner.stub(argumentsPrefix: refresh, with: response)
        let recorder = ActionRecorder()
        let model = GHApprovalViewModel(
            context: context,
            dependencies: harness.dependencies(recorder: recorder),
            codeWait: codeWait
        )
        return Fixture(harness: harness, recorder: recorder, model: model)
    }

    private static func ended(_ model: GHApprovalViewModel) async -> Bool {
        await TestFixtures.eventually { !model.isRunning }
    }

    // MARK: - The code

    @Test(arguments: [pipedOutput, ttyOutput])
    func theCodeShowsWithCopyThenTheApprovalEndsIt(output: String) async throws {
        let fixture = try await Self.fixture(FakeCommandRunner.Response(streamedStderr: output, waitsForCancellation: true))
        let model = fixture.model
        model.start()
        #expect(await TestFixtures.eventually { model.phase == .waiting(GHDeviceCodeModel(code: Self.code)) })
        model.copyCode()
        #expect(fixture.harness.pasteboardString == Self.code)
        #expect(model.isCodeCopied)
        let call = try #require(fixture.harness.runner.invocations.last { $0.arguments.starts(with: Self.refresh) })
        #expect(call.arguments == ["auth", "refresh", "-h", "github.com", "-s", "admin:org"])
        #expect(call.environment["GH_TOKEN"] == nil)
        model.cancel()
        #expect(await Self.ended(model))
    }

    @Test func ghFinishingApprovesAndReloadsTheSidebar() async throws {
        let fixture = try await Self.fixture(FakeCommandRunner.Response(streamedStderr: Self.pipedOutput))
        fixture.harness.stubAuthStatus(Self.approvedStatus)
        let cache = fixture.harness.data.github.tokenCache
        cache.store(SecretBytes(utf8: TestFixtures.token), for: "user-a")
        fixture.model.start()
        #expect(await Self.ended(fixture.model))
        #expect(fixture.model.phase == .approved)
        #expect(fixture.recorder.refreshes == [.catalog])
        #expect(cache.token(for: "user-a") == nil, "the refreshed token is read again")
    }

    @Test func ghExitingZeroWithoutTheScopesShowsTheErrorAndTheCommand() async throws {
        let fixture = try await Self.fixture(FakeCommandRunner.Response(streamedStderr: Self.pipedOutput))
        fixture.model.start()
        #expect(await Self.ended(fixture.model))
        #expect(fixture.model.phase == .failed(.failed))
        #expect(fixture.recorder.refreshes.isEmpty)
    }

    @Test func aSwitchInTerminalSinceTheSidebarLoadedRunsNoRefresh() async throws {
        let fixture = try await Self.fixture(FakeCommandRunner.Response(streamedStderr: Self.pipedOutput))
        fixture.harness.stubAuthStatus(Self.userBActive)
        fixture.model.start()
        #expect(await Self.ended(fixture.model))
        #expect(fixture.model.phase == .failed(.notActiveAccount))
        #expect(!fixture.harness.runner.invocations.contains { $0.arguments.starts(with: Self.refresh) })
    }

    // MARK: - Check Again and Cancel

    @Test func checkAgainFindsTheScopesAndStopsGH() async throws {
        let fixture = try await Self.fixture(FakeCommandRunner.Response(streamedStderr: Self.pipedOutput, waitsForCancellation: true))
        let model = fixture.model
        model.start()
        #expect(await TestFixtures.eventually { model.phase != .starting })
        await model.checkAgain()
        #expect(model.phase == .waiting(GHDeviceCodeModel(code: Self.code)), "not approved yet: gh keeps waiting")
        #expect(model.isRunning)

        fixture.harness.stubAuthStatus(Self.approvedStatus)
        await model.checkAgain()
        #expect(model.phase == .approved)
        #expect(!model.isRunning)
        #expect(fixture.recorder.refreshes == [.catalog])
    }

    @Test func cancelEndsGHAndShowsNoError() async throws {
        let fixture = try await Self.fixture(FakeCommandRunner.Response(streamedStderr: Self.pipedOutput, waitsForCancellation: true))
        let model = fixture.model
        model.start()
        #expect(await TestFixtures.eventually { model.phase != .starting })
        model.cancel()
        #expect(!model.isRunning)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.phase == .waiting(GHDeviceCodeModel(code: Self.code)), "a late end of the stopped run changes nothing")
        #expect(fixture.recorder.refreshes.isEmpty)
    }

    @Test func aLockEndsGH() async throws {
        let fixture = try await Self.fixture(FakeCommandRunner.Response(streamedStderr: Self.pipedOutput, waitsForCancellation: true))
        let model = fixture.model
        model.start()
        #expect(await TestFixtures.eventually { model.phase != .starting })
        fixture.harness.app.lock(trigger: .manual)
        #expect(!model.isRunning)
    }

    // MARK: - Failures

    @Test func aTimeoutSaysTheCodeExpiredAndOffersTheCommand() async throws {
        let fixture = try await Self.fixture(FakeCommandRunner.Response(exitCode: 1, didTimeOut: true, streamedStderr: Self.pipedOutput))
        fixture.model.start()
        #expect(await Self.ended(fixture.model))
        #expect(fixture.model.phase == .failed(.timedOut))
        #expect(GHApprovalError.timedOut.presentation.title == "The code expired")
        fixture.model.copyCommand()
        #expect(fixture.harness.pasteboardString == "gh auth refresh -h github.com -s admin:org")
    }

    @Test func ghExitingNonZeroShowsTheGenericErrorAndTheCommand() async throws {
        let response = FakeCommandRunner.Response.failure(stderr: "error refreshing credentials for user-a: HTTP 401")
        let fixture = try await Self.fixture(response)
        fixture.model.start()
        #expect(await Self.ended(fixture.model))
        #expect(fixture.model.phase == .failed(.unrecognizedOutput))
        let presentation = GHApprovalError.unrecognizedOutput.presentation
        #expect(presentation == GHApprovalError.failed.presentation, "one message, whatever gh said")
        #expect(!presentation.message.contains("401"))
        #expect(fixture.model.commandText == "gh auth refresh -h github.com -s admin:org")
    }

    @Test func unknownOutputStopsGHAndShowsTheGenericError() async throws {
        let response = FakeCommandRunner.Response(streamedStderr: "Something gh never printed before\n", waitsForCancellation: true)
        let fixture = try await Self.fixture(response, codeWait: .milliseconds(50))
        fixture.model.start()
        #expect(await Self.ended(fixture.model))
        #expect(fixture.model.phase == .failed(.unrecognizedOutput))
        fixture.model.start()
        #expect(fixture.model.phase == .starting, "Try Again runs gh again")
        fixture.model.cancel()
    }

    // MARK: - Where Approve runs

    private static func owner(_ login: String, account: String, problem: SidebarOwnerProblem) -> SidebarOwnerModel {
        SidebarOwnerModel(
            id: login.lowercased(),
            login: login,
            accountLogin: account,
            ownerType: .organization,
            isPersonal: false,
            isTruncated: false,
            repos: [],
            organization: nil,
            problem: problem
        )
    }

    @Test func approveOpensTheSheetOnlyForGHsActiveAccount() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        harness.stubToken()
        harness.runner.stub(argumentsPrefix: ["org", "list"], with: .success(""))
        harness.runner.stub(argumentsPrefix: ["repo", "list"], with: .success("[]"))
        await harness.app.refreshGHStatus()
        let main = MainViewModel(app: harness.app)
        await main.sidebar.reload()

        #expect(main.approve(Self.owner("example-org", account: "user-a", problem: .needsAdminOrg)))
        #expect(main.activeSheet == .ghApproval(Self.context))
        main.activeSheet = nil
        #expect(!main.approve(Self.owner("user-b", account: "user-b", problem: .missingScopes(["repo", "read:org"]))), "gh refreshes no other account: Settings has the switch commands")
        #expect(!main.approve(Self.owner("example-labs", account: "user-a", problem: .needsOrgAdmin)))
        #expect(main.activeSheet == nil)
        #expect(!harness.runner.invocations.contains { $0.arguments.starts(with: Self.refresh) }, "nothing runs before the sheet")
    }

    @Test func onlyTheFixedScopesOfTheActiveAccountApproveInTheApp() {
        #expect(SidebarOwnerProblem.needsAdminOrg.approvalScopes == [.adminOrg])
        #expect(SidebarOwnerProblem.missingScopes(["repo", "read:org"]).approvalScopes == [.repo, .readOrg])
        #expect(SidebarOwnerProblem.missingScopes(["repo", "workflow"]).approvalScopes == nil, "never a scope outside the list")
        #expect(SidebarOwnerProblem.signedOut.approvalScopes == nil)
        #expect(SidebarOwnerProblem.needsOrgAdmin.approvalScopes == nil)
        #expect(SidebarOwnerProblem.ssoRequired(nil).approvalScopes == nil)
    }
}
