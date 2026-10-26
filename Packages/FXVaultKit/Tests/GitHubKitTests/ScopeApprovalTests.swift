import Foundation
import os
import Testing
@testable import GitHubKit
import VaultCore

/// In-app Approve through `gh auth refresh` (1.0 B4b), against a fake gh: never the real one,
/// which would change the developer's token.
@Suite("Scope approval")
struct ScopeApprovalTests {
    static let code = "4F2C-91AB"
    /// gh on a terminal: colored, then it waits for Enter.
    static let ttyOutput = "\u{1B}[0;33m!\u{1B}[0m First copy your one-time code: \u{1B}[1m\(code)\u{1B}[0m\nPress Enter to open github.com in your browser... "
    /// gh without one (FX Vault's case): the URL to open instead.
    static let pipedOutput = "! First copy your one-time code: \(code)\nOpen this URL to continue in your web browser: https://github.com/login/device\n"
    static let refreshPrefix = ["auth", "refresh"]

    /// Collects the codes `approve` reports.
    final class Codes: Sendable {
        private let codes = OSAllocatedUnfairLock(initialState: [String]())
        var all: [String] { codes.withLock { $0 } }
        func add(_ model: GHDeviceCodeModel) { codes.withLock { $0.append(model.code) } }
    }

    private func approve(
        _ response: FakeCommandRunner.Response,
        scopes: [GHApprovalScope] = [.adminOrg],
        codeWait: Duration = .seconds(30)
    ) async -> (Result<Void, GHApprovalError>, [String], FakeCommandRunner) {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: Self.refreshPrefix, with: response)
        let auth = GHAuthService(service: TestValues.service(runner), tokenCache: GHTokenCache())
        let codes = Codes()
        let result: Result<Void, GHApprovalError>
        do throws(GHApprovalError) {
            try await auth.approve(scopes: scopes, codeWait: codeWait, onDeviceCode: codes.add)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        return (result, codes.all, runner)
    }

    // MARK: - The command

    @Test func refreshAsksForTheFixedScopesOnGitHubOnly() throws {
        let command = try GHAuthService.refreshCommand(scopes: [.adminOrg])
        #expect(command.operation == .authRefresh)
        #expect(command.arguments == ["auth", "refresh", "-h", "github.com", "-s", "admin:org"])
        #expect(!command.operation.requiresToken)
        #expect(command.operation.timeout == Timeouts.ghAuthRefresh)
        let several = try GHAuthService.refreshCommand(scopes: [.adminOrg, .repo, .repo, .readOrg])
        #expect(several.arguments.last == "repo,read:org,admin:org")
        #expect(GHAuthService.refreshCommandText(scopes: [.adminOrg]) == "gh auth refresh -h github.com -s admin:org")
        #expect(throws: GHError.self) { try GHAuthService.refreshCommand(scopes: []) }
    }

    // MARK: - The device code

    @Test(arguments: [ttyOutput, pipedOutput])
    func theCodeIsReadWithOrWithoutATerminal(output: String) {
        #expect(GHDeviceCodeParser.deviceCode(in: output)?.code == Self.code)
    }

    @Test(arguments: [
        "",
        "Opening github.com in your browser\n",
        "! First copy your one-time code: 4f2c-91ab\n",
        "! Your code: 4F2C-91AB\n",
        "one-time code: 4F2C91AB\n",
    ])
    func unknownOutputHasNoCode(output: String) {
        #expect(GHDeviceCodeParser.deviceCode(in: output) == nil)
    }

    @Test func aCodeSplitAcrossChunksIsFoundOnce() {
        let codes = Codes()
        let watcher = GHDeviceCodeWatcher(onCode: codes.add)
        watcher.receive("! First copy your one-time co")
        watcher.receive("de: 4F2C-9")
        #expect(!watcher.hasCode)
        watcher.receive("1AB\nOpen this URL…\n")
        watcher.receive(Self.pipedOutput)
        #expect(codes.all == [Self.code])
    }

    // MARK: - Running gh

    @Test func theCodeShowsThenAnApprovalEndsIt() async {
        let (result, codes, runner) = await approve(FakeCommandRunner.Response(streamedStderr: Self.pipedOutput))
        #expect((try? result.get()) != nil)
        #expect(codes == [Self.code])
        let call = runner.invocations.first
        #expect(call?.arguments == ["auth", "refresh", "-h", "github.com", "-s", "admin:org"])
        #expect(call?.environment["GH_TOKEN"] == nil, "gh refreshes its stored login, never a GH_TOKEN")
        #expect(call?.timeout == Timeouts.ghAuthRefresh)
    }

    @Test func aTimeoutSaysTheCodeExpired() async {
        let (result, codes, _) = await approve(
            FakeCommandRunner.Response(exitCode: 1, didTimeOut: true, streamedStderr: Self.pipedOutput)
        )
        #expect(result.failure == .timedOut)
        #expect(codes == [Self.code])
    }

    @Test func ghExitingNonZeroAfterTheCodeFails() async {
        let response = FakeCommandRunner.Response(exitCode: 1, stderr: "error refreshing credentials", streamedStderr: Self.pipedOutput)
        let (result, _, _) = await approve(response)
        #expect(result.failure == .failed)
    }

    @Test func ghExitingNonZeroWithoutACodeIsUnrecognized() async {
        let response = FakeCommandRunner.Response(exitCode: 1, stderr: "The value of the GH_TOKEN environment variable is being used")
        let (result, codes, _) = await approve(response)
        #expect(result.failure == .unrecognizedOutput)
        #expect(codes.isEmpty)
    }

    @Test func ghWaitingWithoutACodeIsStopped() async {
        let response = FakeCommandRunner.Response(streamedStderr: "Something new from gh\n", waitsForCancellation: true)
        let (result, codes, _) = await approve(response, codeWait: .milliseconds(50))
        #expect(result.failure == .unrecognizedOutput)
        #expect(codes.isEmpty)
    }

    @Test func aCodeKeepsGHWaitingPastTheCodeWait() async {
        let runner = FakeCommandRunner()
        runner.stub(
            argumentsPrefix: Self.refreshPrefix,
            with: FakeCommandRunner.Response(streamedStderr: Self.pipedOutput, waitsForCancellation: true)
        )
        let auth = GHAuthService(service: TestValues.service(runner), tokenCache: GHTokenCache())
        let codes = Codes()
        let task = Task { () -> GHApprovalError? in
            do throws(GHApprovalError) {
                try await auth.approve(scopes: [.adminOrg], codeWait: .milliseconds(20), onDeviceCode: codes.add)
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(codes.all == [Self.code])
        task.cancel()
        let outcome = await task.value
        #expect(outcome == .cancelled, "Cancel ends gh, still waiting for the approval")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
