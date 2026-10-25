import Darwin
import Foundation
import GitHubKit
import Testing
@testable import DestinationKit
import VaultCore

/// `az account get-access-token` and the `az` locator, through `FakeCommandRunner` and
/// `FakeGHFileInspector` (nothing runs, nothing touches the real file system).
@Suite("Azure CLI")
struct AzureCLITests {
    static let identity = ProcessIdentityModel(
        home: "/Users/user-a",
        user: "user-a",
        temporaryDirectory: "/private/tmp/fxvault-tests"
    )
    static let shell = ShellEnvironmentModel(path: "/Users/user-a/bin:/opt/homebrew/bin:/usr/bin:/bin")
    static let workingDirectory = URL(fileURLWithPath: "/private/tmp/fxvault-tests/empty-cwd", isDirectory: true)
    static let cellarAZ = "/opt/homebrew/Cellar/azure-cli/2.80.0/bin/az"
    static let homebrewAZ = "/opt/homebrew/bin/az"
    static let user = FakeGHFileInspector.defaultUserID

    /// Homebrew's layout: `/opt/homebrew/bin/az` → the Cellar script, folder `rwxrwxr-x admin`.
    static func homebrewInspector(owner: uid_t = user) -> FakeGHFileInspector {
        let inspector = FakeGHFileInspector()
        inspector.addFolder("/opt/homebrew/bin", owner: owner, mode: FakeGHFileInspector.groupWritableFolderMode)
        inspector.addFolder("/opt/homebrew/Cellar/azure-cli/2.80.0/bin", owner: owner)
        inspector.addFile(cellarAZ, owner: owner)
        inspector.addSymlink(homebrewAZ, to: cellarAZ)
        return inspector
    }

    private static func tokenJSON(token: String = TestValues.azureToken, expiresOn epoch: Int = 1_790_003_600) -> String {
        """
        {
          "accessToken": "\(token)",
          "expiresOn": "2026-09-21 15:13:20.000000",
          "expires_on": \(epoch),
          "subscription": "00000000-0000-0000-0000-000000000000",
          "tenant": "\(TestValues.tenantID)",
          "tokenType": "Bearer"
        }
        """
    }

    private static func provider(
        _ runner: FakeCommandRunner,
        clock: InstantClock = InstantClock(),
        inspector: FakeGHFileInspector = homebrewInspector(),
        configDirectory: String? = nil
    ) -> AzureCLITokenProvider {
        AzureCLITokenProvider(
            runner: runner,
            locator: AzureCLILocator(fileInspector: inspector),
            identity: identity,
            shell: shell,
            workingDirectory: workingDirectory,
            azureConfigDirectory: configDirectory,
            clock: clock
        )
    }

    // MARK: - Command

    @Test func argumentsAndEnvironmentAreExact() throws {
        #expect(try AzureCLITokenProvider.arguments(tenantID: nil) == [
            "account", "get-access-token", "--resource", "https://vault.azure.net", "--output", "json",
        ])
        #expect(try AzureCLITokenProvider.arguments(tenantID: TestValues.tenantID) == [
            "account", "get-access-token", "--resource", "https://vault.azure.net", "--tenant", TestValues.tenantID, "--output", "json",
        ])
        #expect(try AzureCLITokenProvider.arguments(tenantID: "example-org.onmicrosoft.com").contains("example-org.onmicrosoft.com"))
        for tenant in ["--subscription", "a b", "", "x;rm"] {
            #expect(throws: DestinationError.invalidInput(.invalidDestinationTarget(.tenantID))) {
                try AzureCLITokenProvider.arguments(tenantID: tenant)
            }
        }

        let environment = AzureCLIRunner.environment(identity: Self.identity, shell: Self.shell, azureConfigDirectory: nil)
        #expect(environment == [
            "HOME": "/Users/user-a",
            "PATH": "/Users/user-a/bin:/opt/homebrew/bin:/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "TMPDIR": "/private/tmp/fxvault-tests",
            "AZURE_CORE_COLLECT_TELEMETRY": "no",
            "AZURE_CORE_NO_COLOR": "true",
            "AZURE_CORE_ONLY_SHOW_ERRORS": "true",
        ])
        let withConfig = AzureCLIRunner.environment(
            identity: ProcessIdentityModel(home: "/Users/user-a", user: "user-a", temporaryDirectory: ""),
            shell: .empty,
            azureConfigDirectory: "/Users/user-a/.azure-work"
        )
        #expect(withConfig["AZURE_CONFIG_DIR"] == "/Users/user-a/.azure-work")
        #expect(withConfig["TMPDIR"] == nil)
        #expect(withConfig["PATH"] == GHConstants.defaultPATH)
        #expect(withConfig["USER"] == nil && withConfig["GH_TOKEN"] == nil)
    }

    @Test func runsTheTrustedResolvedBinaryWithEmptyStdin() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["account", "get-access-token"], with: .success(Self.tokenJSON()))
        let token = try await Self.provider(runner).token(tenantID: TestValues.tenantID)
        #expect(token.testText == TestValues.azureToken)

        let invocation = try #require(runner.invocations.first)
        #expect(invocation.executablePath == Self.cellarAZ, "the checked, resolved path runs")
        #expect(invocation.arguments.contains("--tenant"))
        #expect(invocation.stdin.isEmpty)
        #expect(invocation.timeout == Timeouts.azAccessToken)
        #expect(invocation.workingDirectory == Self.workingDirectory)
        #expect(Set(invocation.environment.keys) == ["HOME", "PATH", "LANG", "TMPDIR", "AZURE_CORE_COLLECT_TELEMETRY", "AZURE_CORE_NO_COLOR", "AZURE_CORE_ONLY_SHOW_ERRORS"])
        #expect(!invocation.arguments.contains(TestValues.azureToken))
    }

    // MARK: - Parsing

    @Test func parsesTokenAndExpiry() throws {
        let parsed = try AzureCLITokenProvider.parse(stdout: TestValues.secret(Self.tokenJSON()))
        #expect(parsed.token.testText == TestValues.azureToken)
        #expect(parsed.expiresAt == Date(timeIntervalSince1970: 1_790_003_600))

        let textEpoch = #"{"accessToken":"\#(TestValues.azureToken)","expires_on":"1790003600"}"#
        #expect(try AzureCLITokenProvider.parse(stdout: TestValues.secret(textEpoch)).expiresAt == Date(timeIntervalSince1970: 1_790_003_600))

        let older = #"{"accessToken":"\#(TestValues.azureToken)","expiresOn":"2026-09-21 15:13:20.000000"}"#
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(try AzureCLITokenProvider.parse(stdout: TestValues.secret(older), timeZone: utc).expiresAt == Date(timeIntervalSince1970: 1_790_003_600))
        let olderNoFraction = #"{"accessToken":"\#(TestValues.azureToken)","expiresOn":"2026-09-21 15:13:20"}"#
        #expect(try AzureCLITokenProvider.parse(stdout: TestValues.secret(olderNoFraction), timeZone: utc).expiresAt == Date(timeIntervalSince1970: 1_790_003_600))
    }

    @Test(arguments: [
        "",
        "not json",
        #"{"expires_on":1790003600}"#,
        #"{"accessToken":"","expires_on":1790003600}"#,
        #"{"accessToken":"has space","expires_on":1790003600}"#,
        #"{"accessToken":"line\nbreak","expires_on":1790003600}"#,
        #"{"accessToken":"abc"}"#,
        #"{"accessToken":"abc","expiresOn":"tomorrow"}"#,
    ])
    func unreadableOutputIsDecoding(stdout: String) {
        #expect(throws: DestinationError.decoding) {
            try AzureCLITokenProvider.parse(stdout: TestValues.secret(stdout))
        }
    }

    // MARK: - Caching

    @Test func tokensAreCachedUntilTheRefreshMargin() async throws {
        let runner = FakeCommandRunner()
        let clock = InstantClock()
        runner.stub(argumentsPrefix: ["account"], with: .success(Self.tokenJSON(expiresOn: Int(InstantClock.start.timeIntervalSince1970) + 3600)))
        let provider = Self.provider(runner, clock: clock)
        _ = try await provider.token(tenantID: nil)
        _ = try await provider.token(tenantID: nil)
        #expect(runner.invocations.count == 1)

        let margin = Timeouts.accessTokenRefreshMargin.timeInterval
        clock.advanceWallClock(by: 3600 - margin - 1)
        _ = try await provider.token(tenantID: nil)
        #expect(runner.invocations.count == 1, "still before expiry minus the margin")
        clock.advanceWallClock(by: 1)
        _ = try await provider.token(tenantID: nil)
        #expect(runner.invocations.count == 2, "refreshed inside the margin")
    }

    @Test func cachesArePerTenantAndInvalidateRefetches() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["account"], with: .success(Self.tokenJSON(expiresOn: 1_800_000_000)))
        let provider = Self.provider(runner)
        _ = try await provider.token(tenantID: nil)
        _ = try await provider.token(tenantID: TestValues.tenantID)
        _ = try await provider.token(tenantID: TestValues.tenantID)
        #expect(runner.invocations.count == 2)
        #expect(runner.invocations.map { $0.arguments.contains("--tenant") } == [false, true])

        await provider.invalidate(tenantID: TestValues.tenantID)
        _ = try await provider.token(tenantID: nil)
        #expect(runner.invocations.count == 2, "the other tenant's token is kept")
        _ = try await provider.token(tenantID: TestValues.tenantID)
        #expect(runner.invocations.count == 3)
    }

    @Test func returnedTokensAreCopies() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["account"], with: .success(Self.tokenJSON(expiresOn: 1_800_000_000)))
        let provider = Self.provider(runner)
        let first = try await provider.token(tenantID: nil)
        first.wipe()
        let second = try await provider.token(tenantID: nil)
        #expect(second.testText == TestValues.azureToken, "wiping a returned token leaves the cache intact")
    }

    @Test func concurrentRequestsShareOneRun() async throws {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["account"], with: .success(Self.tokenJSON(expiresOn: 1_800_000_000)))
        let provider = Self.provider(runner)
        async let first = provider.token(tenantID: nil)
        async let second = provider.token(tenantID: nil)
        let tokens = try await [first, second]
        #expect(tokens.allSatisfy { $0.testText == TestValues.azureToken })
        #expect(runner.invocations.count == 1)
    }

    // MARK: - Failures

    @Test(arguments: [
        ("ERROR: Please run 'az login' to setup account.", DestinationError.azNotSignedIn),
        ("ERROR: AADSTS700082: The refresh token has expired due to inactivity.\nInteractive authentication is needed. Please run:\naz login --scope https://vault.azure.net/.default", .azNotSignedIn),
        ("ERROR: The command failed with an unexpected error.", .azFailed(exitCode: 1)),
        ("", .azFailed(exitCode: 1)),
    ])
    func failuresAreClassifiedFromStderr(stderr: String, expected: DestinationError) async {
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["account"], with: .failure(stderr: stderr))
        await #expect(throws: expected) {
            try await Self.provider(runner).token(tenantID: nil)
        }
    }

    @Test func classificationRunsOnRedactedStderr() {
        let jwt = "eyJ" + String(repeating: "A", count: 30) + "." + String(repeating: "b", count: 20) + "." + String(repeating: "c", count: 10)
        let stderr = "ERROR: token \(jwt) rejected; Please run 'az login'"
        let redacted = AzureStderrRedactor.redact(stderr)
        #expect(!redacted.contains(jwt))
        #expect(redacted.contains(GHConstants.redactionPlaceholder))
        #expect(redacted.contains("az login"))
        #expect(AzureStderrRedactor.redact("eyJshort") == "eyJshort", "short text is not a token")
        let result = CommandResult(exitCode: 1, stdout: SecretBytes(count: 0), stderr: stderr)
        #expect(AzureCLIRunner.classify(result) == .azNotSignedIn)
    }

    @Test func timeoutsLaunchFailuresAndCancellation() async {
        let cases: [(FakeCommandRunner.Response, DestinationError)] = [
            (FakeCommandRunner.Response(exitCode: 15, didTimeOut: true), .timeout),
            (FakeCommandRunner.Response(error: .launchFailed(errno: ENOENT)), .azNotInstalled),
            (FakeCommandRunner.Response(error: .launchFailed(errno: EACCES)), .azFailed(exitCode: AzureCLIRunner.launchFailedExitCode)),
            (FakeCommandRunner.Response(error: .cancelled), .cancelled),
        ]
        for (response, expected) in cases {
            let runner = FakeCommandRunner()
            runner.stub(argumentsPrefix: ["account"], with: response)
            await #expect(throws: expected) {
                try await Self.provider(runner).token(tenantID: nil)
            }
        }
    }

    @Test func failuresAreNotCached() async throws {
        let runner = FakeCommandRunner()
        runner.enqueue(.failure(stderr: "ERROR: Please run 'az login' to setup account."))
        runner.stub(argumentsPrefix: ["account"], with: .success(Self.tokenJSON(expiresOn: 1_800_000_000)))
        let provider = Self.provider(runner)
        await #expect(throws: DestinationError.azNotSignedIn) {
            try await provider.token(tenantID: nil)
        }
        #expect(try await provider.token(tenantID: nil).testText == TestValues.azureToken)
    }

    @Test func missingOrUntrustedAZStopsBeforeRunning() async {
        let runner = FakeCommandRunner()
        await #expect(throws: DestinationError.azNotInstalled) {
            try await Self.provider(runner, inspector: FakeGHFileInspector()).token(tenantID: nil)
        }
        await #expect(throws: DestinationError.azUntrusted(path: Self.homebrewAZ)) {
            try await Self.provider(runner, inspector: Self.homebrewInspector(owner: 502)).token(tenantID: nil)
        }
        #expect(runner.invocations.isEmpty)
    }

    // MARK: - Locator

    @Test func candidateOrder() {
        let candidates = AzureCLILocator.candidates(overridePath: nil, shell: Self.shell, home: "/Users/user-a").map(\.path)
        #expect(candidates == ["/Users/user-a/bin/az", "/opt/homebrew/bin/az", "/usr/bin/az", "/bin/az", "/usr/local/bin/az"])
        #expect(AzureCLILocator.candidates(overridePath: "~/tools/az", shell: Self.shell, home: "/Users/user-a").map(\.path) == ["/Users/user-a/tools/az"])
        #expect(AzureCLILocator.candidates(overridePath: "tools/az", shell: Self.shell, home: "/Users/user-a").isEmpty, "relative paths are never searched")
        #expect(AzureCLILocator.candidates(overridePath: nil, shell: ShellEnvironmentModel(path: "relative:/opt/homebrew/bin"), home: "/").map(\.path) == ["/opt/homebrew/bin/az", "/usr/local/bin/az"])
    }

    @Test func acceptsHomebrewAZ() throws {
        let installation = try AzureCLILocator(fileInspector: Self.homebrewInspector()).locate(overridePath: nil, shell: Self.shell, home: "/Users/user-a")
        #expect(installation == AzureCLIInstallationModel(path: Self.homebrewAZ, resolvedPath: Self.cellarAZ))
        let rootOwned = try AzureCLILocator(fileInspector: Self.homebrewInspector(owner: 0)).locate(overridePath: nil, shell: Self.shell, home: "/Users/user-a")
        #expect(rootOwned.resolvedPath == Self.cellarAZ)
    }

    @Test func firstExistingCandidateDecides() {
        let inspector = Self.homebrewInspector()
        inspector.addFolder("/Users/user-a/bin", owner: Self.user, group: FakeGHFileInspector.staffGroupID, mode: 0o777)
        inspector.addFile("/Users/user-a/bin/az", owner: Self.user)
        #expect(throws: DestinationError.azUntrusted(path: "/Users/user-a/bin/az"), "never falls back to the trusted Homebrew az behind it") {
            try AzureCLILocator(fileInspector: inspector).locate(overridePath: nil, shell: Self.shell, home: "/Users/user-a")
        }
    }

    @Test(arguments: [
        (FakeGHFileInspector.staffGroupID, mode_t(0o775), mode_t(0o755), false),
        (FakeGHFileInspector.adminGroupID, mode_t(0o775), mode_t(0o755), true),
        (FakeGHFileInspector.adminGroupID, mode_t(0o757), mode_t(0o755), false),
        (FakeGHFileInspector.adminGroupID, mode_t(0o755), mode_t(0o777), false),
        (FakeGHFileInspector.adminGroupID, mode_t(0o755), mode_t(0o644), false),
    ])
    func trustRules(group: gid_t, folderMode: mode_t, fileMode: mode_t, accepted: Bool) {
        let inspector = FakeGHFileInspector()
        inspector.addFolder("/usr/local/bin", owner: Self.user, group: group, mode: folderMode)
        inspector.addFile("/usr/local/bin/az", owner: Self.user, group: group, mode: fileMode)
        let result = Result { () throws(DestinationError) in
            try AzureCLILocator(fileInspector: inspector).locate(overridePath: nil, shell: .empty, home: "/Users/user-a")
        }
        if accepted {
            #expect((try? result.get())?.resolvedPath == "/usr/local/bin/az")
        } else {
            #expect(throws: DestinationError.azUntrusted(path: "/usr/local/bin/az")) { try result.get() }
        }
    }

    @Test func overrideIsTheOnlyCandidate() {
        let inspector = Self.homebrewInspector()
        #expect(throws: DestinationError.azNotInstalled, "a missing override never falls back") {
            try AzureCLILocator(fileInspector: inspector).locate(overridePath: "/Users/user-a/tools/az", shell: Self.shell, home: "/Users/user-a")
        }
        #expect((try? AzureCLILocator(fileInspector: inspector).locate(overridePath: Self.homebrewAZ, shell: .empty, home: "/"))?.resolvedPath == Self.cellarAZ)
    }
}
