import Darwin
import Foundation
import os
import Testing
@testable import GitHubKit
import VaultCore

/// A runner whose behavior is a closure (clone side effects, concurrency probes).
final class ClosureRunner: CommandRunning, Sendable {
    typealias Handler = @Sendable (CommandSpec, Int) async -> CommandResult
    private let handler: Handler
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var callCount: Int {
        calls.withLock { $0 }
    }

    func run(_ spec: CommandSpec) async throws(CommandRunnerError) -> CommandResult {
        spec.stdin.discard()
        let index = calls.withLock { count -> Int in
            count += 1
            return count
        }
        return await handler(spec, index)
    }

    static func result(exitCode: Int32 = 0, stdout: String = "", stderr: String = "", didTimeOut: Bool = false) -> CommandResult {
        CommandResult(exitCode: exitCode, didTimeOut: didTimeOut, stdout: SecretBytes(utf8: stdout), stderr: stderr)
    }
}

@Suite("GHCommandService")
struct GHCommandServiceTests {
    @Test func runsWithTheAllowlistedEnvironmentAndToken() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["secret", "list"], with: .success(try Fixture.string("gh/secret-list.json")))
        let service = TestValues.service(runner)
        let output = try await service.execute(
            try GHSecretsCommands.list(repo: try TestValues.repo()),
            token: TestValues.secret(TestValues.token)
        )
        #expect(try GHSecretsCommands.decodeList(output).count == 2)
        let call = try #require(runner.invocations.first)
        #expect(call.executablePath == TestValues.ghURL.path)
        #expect(call.workingDirectory == TestValues.workingDirectory)
        #expect(call.environment[ProcessEnvironmentBuilder.Key.ghToken] == TestValues.token)
        #expect(Set(call.environment.keys).isSubset(of: ProcessEnvironmentBuilder.ghAllowedKeys))
        #expect(call.timeout == Timeouts.ghDefault)
        #expect(call.stdin.isEmpty)
    }

    @Test func authCommandsNeverReceiveTheToken() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["auth", "status"], with: .success(try Fixture.string("gh/auth-status.json")))
        let service = TestValues.service(runner)
        _ = try await service.execute(try GHAuthService.statusCommand(), token: TestValues.secret(TestValues.token))
        #expect(runner.invocations.first?.environment[ProcessEnvironmentBuilder.Key.ghToken] == nil)
    }

    @Test func tokenOperationsWithoutATokenFail() async throws {
        let service = TestValues.service(FakeCommandRunner())
        await #expect(throws: GHError.notAuthenticated) {
            try await service.execute(try GHOrgsCommands.list(), token: nil)
        }
    }

    @Test func failuresAreClassifiedAndRedacted() async throws {
        let runner = FakeCommandRunner()
        runner.stub(
            argumentsPrefix: ["variable", "set"],
            with: .failure(stderr: "HTTP 422: value FXV_FIXTURE_SECRET_VALUE is invalid (https://api.github.com/x) \(TestValues.token)")
        )
        let service = TestValues.service(runner)
        let command = try GHVariablesCommands.set(
            name: "A", repo: try TestValues.repo(), value: TestValues.secret("FXV_FIXTURE_SECRET_VALUE"), isUpdate: false
        )
        do {
            _ = try await service.execute(command, token: TestValues.secret(TestValues.token))
            Issue.record("expected a validation error")
        } catch {
            guard case .validation(let message) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(!message.contains("FXV_FIXTURE_SECRET_VALUE"))
            #expect(!message.contains(TestValues.token))
            #expect(message.contains(GHConstants.redactionPlaceholder))
        }
    }

    @Test func includeHeadStatusDrivesClassification() async throws {
        let runner = FakeCommandRunner()
        runner.enqueue(FakeCommandRunner.Response(exitCode: 1, stdout: try Fixture.data("api/environment-get-404.txt")))
        let service = TestValues.service(runner)
        await #expect(throws: GHError.notFound) {
            try await service.execute(
                try GHEnvironmentsAPI.get(repo: try TestValues.repo(), environment: "gone"),
                token: TestValues.secret(TestValues.token)
            )
        }
    }

    @Test func bare303OnBranchPolicyAddIsSuccess() async throws {
        let runner = FakeCommandRunner()
        runner.enqueue(FakeCommandRunner.Response(
            exitCode: 1,
            stdout: try Fixture.data("api/branch-policy-add-303.txt"),
            stderr: "gh: HTTP 303\n"
        ))
        let service = TestValues.service(runner)
        let output = try await service.execute(
            try GHEnvironmentsAPI.addBranchPolicy(repo: try TestValues.repo(), environment: "prod", pattern: "main", type: .branch),
            token: TestValues.secret(TestValues.token)
        )
        #expect(output.response?.status == 303)
        #expect(try GHEnvironmentsAPI.decodeAddedBranchPolicy(output) == nil)
        #expect(runner.invocations.first?.stdin == Data(#"{"name":"main","type":"branch"}"#.utf8))
    }

    @Test func the303ExceptionAppliesOnlyToBranchPolicyAdd() async throws {
        let runner = FakeCommandRunner()
        runner.enqueue(FakeCommandRunner.Response(
            exitCode: 1,
            stdout: try Fixture.data("api/branch-policy-add-303.txt"),
            stderr: "gh: HTTP 303\n"
        ))
        await #expect(throws: GHError.unexpected(exitCode: 1)) {
            try await TestValues.service(runner).execute(
                try GHEnvironmentsAPI.delete(repo: try TestValues.repo(), environment: "prod"),
                token: TestValues.secret(TestValues.token)
            )
        }
    }

    @Test func truncatedOutputIsAnError() async throws {
        let runner = FakeCommandRunner()
        runner.enqueue(FakeCommandRunner.Response(stdout: Data("[".utf8), isStdoutTruncated: true))
        await #expect(throws: GHError.outputTooLarge) {
            try await TestValues.service(runner).execute(
                try GHReposCommands.list(owner: "owner-a"),
                token: TestValues.secret(TestValues.token)
            )
        }
    }

    @Test(arguments: [
        (CommandRunnerError.launchFailed(errno: ENOENT), GHError.notInstalled),
        (CommandRunnerError.launchFailed(errno: EACCES), GHError.launchFailed),
        (CommandRunnerError.cancelled, GHError.cancelled),
    ])
    func runnerErrorsMap(runnerError: CommandRunnerError, expected: GHError) async throws {
        let runner = FakeCommandRunner()
        runner.enqueue(FakeCommandRunner.Response(error: runnerError))
        await #expect(throws: expected) {
            try await TestValues.service(runner).execute(try GHAuthService.statusCommand(), token: nil)
        }
    }

    @Test func missingWorkingDirectoryIsNotReportedAsMissingGH() async throws {
        let gh = try TemporaryDirectory()
        let executable = try gh.file("gh", contents: "#!/bin/sh\nexit 0\n", mode: 0o755)
        let service = GHCommandService(
            executableURL: executable,
            identity: TestValues.identity,
            shell: TestValues.shell,
            workingDirectory: gh.url.appendingPathComponent("missing-cwd"),
            runner: ProcessRunner()
        )
        await #expect(throws: GHError.launchFailed) { try await service.execute(try GHLocator.versionCommand(), token: nil) }
        let missing = GHCommandService(
            executableURL: gh.url.appendingPathComponent("absent-gh"),
            identity: TestValues.identity,
            shell: TestValues.shell,
            workingDirectory: gh.url,
            runner: ProcessRunner()
        )
        await #expect(throws: GHError.notInstalled) { try await missing.execute(try GHLocator.versionCommand(), token: nil) }
    }

    @Test func timeoutsSplitReadsFromWrites() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: [], with: FakeCommandRunner.Response(exitCode: 143, didTimeOut: true))
        let service = TestValues.service(runner)
        let token = TestValues.secret(TestValues.token)
        let repo = try TestValues.repo()
        await #expect(throws: GHError.timeout) {
            try await service.execute(try GHSecretsCommands.list(repo: repo), token: token)
        }
        await #expect(throws: GHError.indeterminate) {
            try await service.execute(try GHSecretsCommands.set(name: "A", repo: repo, value: TestValues.secret("v")), token: token)
        }
    }
}

@Suite("GHAuthService and GHTokenCache")
struct GHAuthServiceTests {
    private func auth(_ runner: FakeCommandRunner, cache: GHTokenCache = GHTokenCache()) -> GHAuthService {
        GHAuthService(service: TestValues.service(runner), tokenCache: cache)
    }

    @Test func accountsFromAuthStatus() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["auth", "status"], with: .success(try Fixture.string("gh/auth-status-multi.json")))
        let accounts = try await auth(runner).accounts()
        #expect(accounts.count == 6)
        #expect(accounts.first(where: \.isActive)?.login == "user-a")
    }

    @Test func tokensAreFetchedOnceAndCached() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["auth", "token"], with: .success("\(TestValues.token)\n"))
        let service = auth(runner)
        let first = try await service.token(for: "user-a")
        let second = try await service.token(for: "USER-A")
        #expect(first.utf8String() == TestValues.token)
        #expect(second.utf8String() == TestValues.token)
        #expect(first !== second, "callers get copies")
        first.wipe()
        #expect(service.tokenCache.token(for: "user-a")?.utf8String() == TestValues.token, "wiping a copy keeps the cache")
        let tokenCalls = runner.invocations.filter { $0.arguments.starts(with: ["auth", "token"]) }
        #expect(tokenCalls.count == 1)
        #expect(tokenCalls.first?.arguments.last == "--user=user-a")
        #expect(tokenCalls.first?.timeout == Timeouts.ghAuthToken)
    }

    @Test func purgeIsSynchronousAndWipes() {
        let cache = GHTokenCache()
        let stored = TestValues.secret(TestValues.token)
        cache.store(stored, for: "user-a")
        cache.store(TestValues.secret(TestValues.otherToken), for: "user-b")
        #expect(cache.count == 2)
        cache.purge()
        #expect(stored.isWiped, "purge wipes before returning")
        #expect(cache.count == 0)
        #expect(cache.token(for: "user-a") == nil)
    }

    @Test func invalidateAndReplace() {
        let cache = GHTokenCache()
        let old = TestValues.secret(TestValues.token)
        cache.store(old, for: "user-a")
        cache.store(TestValues.secret(TestValues.otherToken), for: "user-a")
        #expect(old.isWiped, "a replaced token is wiped")
        cache.invalidate(login: "USER-A")
        #expect(cache.token(for: "user-a") == nil)
    }

    @Test func refreshReportsWhetherTheTokenChanged() async throws {
        let runner = FakeCommandRunner()
        runner.enqueue(.success(TestValues.otherToken), matching: Match.prefix(["auth", "token"]))
        runner.enqueue(.success(TestValues.otherToken), matching: Match.prefix(["auth", "token"]))
        let service = auth(runner)
        #expect(try await service.refreshToken(for: "user-a", replacing: TestValues.secret(TestValues.token)))
        #expect(!(try await service.refreshToken(for: "user-a", replacing: TestValues.secret(TestValues.otherToken))))
    }
}

@Suite("GHCommandScheduler")
struct GHCommandSchedulerTests {
    private func scheduler(_ runner: any CommandRunning, clock: ManualClock = ManualClock()) -> GHCommandScheduler {
        let service = TestValues.service(runner)
        return GHCommandScheduler(
            accountLogin: "user-a",
            service: service,
            auth: GHAuthService(service: service, tokenCache: GHTokenCache()),
            clock: clock
        )
    }

    private static let tokenPrefix = ["auth", "token"]

    @Test func tokenRevokedRefreshesOnceAndRetriesWithTheNewToken() async throws {
        let runner = FakeCommandRunner()
        runner.enqueue(.success(TestValues.token), matching: Match.prefix(Self.tokenPrefix))
        runner.enqueue(.success(TestValues.otherToken), matching: Match.prefix(Self.tokenPrefix))
        runner.enqueue(
            .failure(stderr: "HTTP 401: Bad credentials (https://api.github.com/user)\nTry authenticating with:  gh auth login -h github.com"),
            matching: Match.prefix(["secret", "list"])
        )
        runner.enqueue(.success("[]"), matching: Match.prefix(["secret", "list"]))
        let secrets = try await scheduler(runner).listSecrets(try TestValues.repo())
        #expect(secrets.isEmpty)
        let lists = runner.invocations.filter { $0.arguments.starts(with: ["secret", "list"]) }
        #expect(lists.map { $0.environment[ProcessEnvironmentBuilder.Key.ghToken] } == [TestValues.token, TestValues.otherToken])
    }

    @Test func tokenRevokedWithTheSameTokenGivesUp() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: Self.tokenPrefix, with: .success(TestValues.token))
        runner.stub(argumentsPrefix: ["secret", "list"], with: .failure(stderr: "HTTP 401: Bad credentials"))
        await #expect(throws: GHError.tokenRevoked) {
            try await scheduler(runner).listSecrets(try TestValues.repo())
        }
        #expect(runner.invocations.filter { $0.arguments.starts(with: ["secret", "list"]) }.count == 1)
        #expect(runner.invocations.filter { $0.arguments.starts(with: Self.tokenPrefix) }.count == 2)
    }

    @Test func rateLimitWaitsTheFixedBackoffThenRetries() async throws {
        let clock = ManualClock()
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: Self.tokenPrefix, with: .success(TestValues.token))
        runner.enqueue(.failure(stderr: "HTTP 403: You have exceeded a secondary rate limit."), matching: Match.prefix(["secret", "set"]))
        runner.enqueue(.success(), matching: Match.prefix(["secret", "set"]))
        let scheduler = scheduler(runner, clock: clock)
        let repo = try TestValues.repo()
        let task = Task { try await scheduler.setSecret("A", repo: repo, value: TestValues.secret("v")) }
        await clock.waitForSleepers(count: 1)
        clock.advance(by: Timeouts.rateLimitBackoff)
        try await task.value
        #expect(runner.invocations.filter { $0.arguments.starts(with: ["secret", "set"]) }.count == 2)
        #expect(await scheduler.writesInLastHour == 2, "both attempts count against the budget")
    }

    @Test func rateLimitStopsAfterTheRetryLimit() async throws {
        let clock = ManualClock()
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: Self.tokenPrefix, with: .success(TestValues.token))
        runner.stub(argumentsPrefix: ["secret", "list"], with: .failure(stderr: "gh: HTTP 429"))
        let scheduler = scheduler(runner, clock: clock)
        let repo = try TestValues.repo()
        let task = Task { try await scheduler.listSecrets(repo) }
        for _ in 0..<Limits.rateLimitRetries {
            await clock.waitForSleepers(count: 1)
            clock.advance(by: Timeouts.rateLimitBackoff)
        }
        await #expect(throws: GHError.rateLimited) { try await task.value }
        #expect(runner.invocations.filter { $0.arguments.starts(with: ["secret", "list"]) }.count == Limits.rateLimitRetries + 1)
    }

    @Test func transientFailuresRetryIdempotentCommands() async throws {
        let clock = ManualClock()
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: Self.tokenPrefix, with: .success(TestValues.token))
        runner.enqueue(.failure(stderr: "HTTP 502: Bad Gateway (https://api.github.com/x)"), matching: Match.prefix(["variable", "delete"]))
        runner.enqueue(.success(), matching: Match.prefix(["variable", "delete"]))
        let scheduler = scheduler(runner, clock: clock)
        let repo = try TestValues.repo()
        let task = Task { try await scheduler.deleteVariable("A", repo: repo) }
        await clock.waitForSleepers(count: 1)
        clock.advance(by: Timeouts.idempotentRetryBackoff)
        try await task.value
        #expect(runner.invocations.filter { $0.arguments.starts(with: ["variable", "delete"]) }.count == 2)
    }

    @Test func repoCreateIsNeverRetried() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: Self.tokenPrefix, with: .success(TestValues.token))
        runner.stub(argumentsPrefix: ["repo", "create"], with: .failure(stderr: "HTTP 502: Bad Gateway"))
        let request = GHRepoCreateRequest(repo: try TestValues.repo(), visibility: .private)
        await #expect(throws: GHError.serverError(status: 502)) {
            try await scheduler(runner).createRepository(request)
        }
        #expect(runner.invocations.filter { $0.arguments.starts(with: ["repo", "create"]) }.count == 1)
    }

    @Test func stdinValueIsWipedWhenTheCallEnds() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: Self.tokenPrefix, with: .success(TestValues.token))
        runner.stub(argumentsPrefix: ["secret", "set"], with: .failure(stderr: "HTTP 403: Must have admin rights"))
        let command = try GHSecretsCommands.set(name: "A", repo: try TestValues.repo(), value: TestValues.secret("v"))
        await #expect(throws: GHError.adminRequired) { try await scheduler(runner).run(command) }
        #expect(command.stdinValue?.isWiped == true)
        #expect(runner.invocations.last?.stdin == Data("v".utf8))
    }

    @Test func commandsRunOneAtATime() async throws {
        let inFlight = OSAllocatedUnfairLock(initialState: (current: 0, peak: 0))
        let runner = ClosureRunner { spec, _ in
            inFlight.withLock { $0.current += 1; $0.peak = max($0.peak, $0.current) }
            try? await Task.sleep(for: .milliseconds(10))
            inFlight.withLock { $0.current -= 1 }
            return spec.arguments.starts(with: ["auth", "token"])
                ? ClosureRunner.result(stdout: TestValues.token)
                : ClosureRunner.result(stdout: "[]")
        }
        let scheduler = scheduler(runner, clock: ManualClock())
        let repo = try TestValues.repo()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await scheduler.listSecrets(repo) }
            }
            try await group.waitForAll()
        }
        #expect(inFlight.withLock { $0.peak } == 1)
    }

    @Test func seedingCountsJournalWrites() async throws {
        let clock = ManualClock()
        let scheduler = scheduler(FakeCommandRunner(), clock: clock)
        let now = clock.now
        await scheduler.seed(recentWrites: [
            GHWriteRecordModel(date: now.addingTimeInterval(-60), cost: 1),
            GHWriteRecordModel(date: now.addingTimeInterval(-1800), cost: 2),
            GHWriteRecordModel(date: now.addingTimeInterval(-7200), cost: 5),
        ])
        #expect(await scheduler.writesInLastHour == 3, "only the last hour counts")
        #expect(await scheduler.remainingHourlyBudget == Limits.writesPerHour - 3)
    }

    @Test func exhaustedHourlyBudgetStopsTheRun() async throws {
        let clock = ManualClock()
        let runner = FakeCommandRunner()
        let scheduler = scheduler(runner, clock: clock)
        let now = clock.now
        await scheduler.seed(recentWrites: [GHWriteRecordModel(date: now.addingTimeInterval(-60), cost: Limits.writesPerHour)])
        await #expect(throws: GHError.writeBudgetExhausted) {
            try await scheduler.deleteSecret("A", repo: try TestValues.repo())
        }
        #expect(runner.invocations.isEmpty)
    }
}

@Suite("WriteThrottle")
struct WriteThrottleTests {
    @Test func perMinuteLimitWaitsForTheOldestWrite() {
        var throttle = WriteThrottle()
        for second in 0..<Limits.writesPerMinute {
            throttle.record(cost: 1, at: .seconds(second))
        }
        let now = Duration.seconds(Limits.writesPerMinute)
        // The first write (t = 0) leaves the minute window at t = 60.
        #expect(throttle.decision(forCost: 1, now: now) == .wait(.zero) || throttle.decision(forCost: 1, now: now) == .proceed)
        #expect(throttle.decision(forCost: 1, now: .seconds(59)) == .wait(.seconds(1)))
        #expect(throttle.decision(forCost: 2, now: .seconds(59)) == .wait(.seconds(2)))
    }

    @Test func batchGapAfterTheThreshold() {
        var throttle = WriteThrottle()
        for index in 0..<Limits.writeBatchGapThreshold {
            throttle.record(cost: 1, at: .milliseconds(index * 100))
        }
        let last = Duration.milliseconds((Limits.writeBatchGapThreshold - 1) * 100)
        #expect(throttle.decision(forCost: 1, now: last + .milliseconds(400)) == .wait(.milliseconds(600)))
        #expect(throttle.decision(forCost: 1, now: last + Timeouts.writeBatchGap) == .proceed)
    }

    @Test func hourlyLimitIsExhaustedWhenTheWaitIsLong() {
        var throttle = WriteThrottle()
        throttle.record(cost: Limits.writesPerHour, at: .zero)
        #expect(throttle.decision(forCost: 1, now: .seconds(120)) == .exhausted)
        #expect(throttle.decision(forCost: 1, now: Timeouts.throttleHourWindow - .seconds(30)) == .wait(.seconds(30)))
        #expect(throttle.decision(forCost: 1, now: Timeouts.throttleHourWindow) == .proceed)
    }
}
