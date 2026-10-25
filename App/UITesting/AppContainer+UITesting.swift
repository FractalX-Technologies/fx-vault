#if FXVAULT_UI_TESTING
import DestinationKit
import Foundation
import GitHubKit
import VaultCore
import VaultData

// Compiled only into the UITesting configuration (project.yml), which is its own app,
// "FX Vault UI Test": Debug and Release builds cannot reach this code, and scripts/ci-local.sh
// checks that their binaries have none of its strings.

/// Where the UI-testing host keeps its throwaway vault.
enum UITestLaunch {
    /// The folder of every UI-test run, under the user's temporary directory.
    static let runsDirectoryName = "fxvault-uitests"
    /// Runs older than this are removed at launch; a younger one may belong to a suite still running.
    static let staleRunAge: TimeInterval = 60 * 60

    /// A new, empty, owner-only folder for this launch, so every launch starts with no vault.
    static func prepareRoot(fileManager: FileManager = .default, now: Date = Date()) -> URL {
        let runs = fileManager.temporaryDirectory.appendingPathComponent(runsDirectoryName, isDirectory: true)
        removeStaleRuns(in: runs, fileManager: fileManager, now: now)
        let root = runs.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            preconditionFailure("The UI-test folder could not be created")
        }
        return root
    }

    private static func removeStaleRuns(in runs: URL, fileManager: FileManager, now: Date) {
        let entries = (try? fileManager.contentsOfDirectory(at: runs, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if now.timeIntervalSince(created) > staleRunAge {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}

/// The scripted gh of the UI-testing host: one account (with `admin:org`) that owns one
/// organization with one repository that can be imported (environments `production` and
/// `staging`, one variable in each scope and no secrets) and its own secrets and variables
/// (B12, B13), and is a plain member of a second, empty organization; read commands only. Every other call gets the fake runner's "no stub" failure, so
/// nothing can be written anywhere.
enum UITestGitHub {
    static let account = "owner-a"
    static let organization = "example-org"
    /// An organization where the account is a member, not an admin.
    static let memberOrganization = "example-labs"
    static let repository = "api-service"
    static let token = "fake-token-ui-tests"

    static let authStatus = """
    {"hosts":{"github.com":[
     {"state":"success","active":true,"host":"github.com","login":"\(account)","tokenSource":"keyring","scopes":"admin:org, gist, read:org, repo","gitProtocol":"ssh"}
    ]}}
    """

    /// Writes placeholder `gh` and `az` binaries (never run: the fake runner answers every
    /// call) where the trust checks accept them, an owner-only folder of the current user that
    /// leads the probed PATH, so no real `az` in the Homebrew folders is found. Returns gh's path.
    static func installPlaceholder(in bin: URL, fileManager: FileManager = .default) throws -> String {
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["gh", "az"] {
            let binary = bin.appendingPathComponent(name, isDirectory: false)
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: binary)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        }
        return bin.appendingPathComponent("gh", isDirectory: false).path
    }

    /// `bin` is the shell probe's whole PATH (plus the system folders), so no locator looks at a
    /// real gh or az.
    static func makeRunner(ghPath: String, bin: URL) -> FakeCommandRunner {
        let runner = FakeCommandRunner()
        runner.stub(
            argumentsPrefix: ["-i", "-l", "-c"],
            with: .success(FakeGHOutput.shellProbe(ghPath: ghPath, path: "\(bin.path):/usr/bin:/bin"))
        )
        runner.stub(argumentsPrefix: ["--version"], with: .success("gh version \(Limits.minimumGHVersion) (2026-09-01)\n"))
        runner.stub(argumentsPrefix: ["auth", "status"], with: .success(authStatus))
        runner.stub(argumentsPrefix: ["auth", "token"], with: .success(token + "\n"))
        runner.stub(argumentsPrefix: ["org", "list"], with: .success("\(organization)\n\(memberOrganization)\n"))
        runner.stub(argumentsPrefix: ["repo", "list", account], with: .success("[]"))
        runner.stub(argumentsPrefix: ["repo", "list", memberOrganization], with: .success("[]"))
        runner.stub(
            argumentsPrefix: ["repo", "list", organization],
            with: .success("[\(FakeGHOutput.repo(owner: organization, name: repository, permission: "ADMIN"))]")
        )
        stubImport(on: runner)
        UITestAzure.stub(on: runner)
        return runner
    }

    private static var fullName: String { "\(organization)/\(repository)" }

    /// The `gh api` reads: each organization's role (B4), and what Import reads (`repo view`, the
    /// environments with open branch policies, so no policy call, and the secret and variable
    /// lists of each scope).
    private static func stubImport(on runner: FakeCommandRunner) {
        // Locals: the Sendable handlers below cannot read the main-actor statics.
        let fullName = fullName
        let organization = organization
        let memberOrganization = memberOrganization
        runner.stub(
            argumentsPrefix: ["repo", "view", fullName],
            with: .success(FakeGHOutput.repo(owner: organization, name: repository, permission: "ADMIN"))
        )
        let environments = """
        [{"total_count":2,"environments":[
         {"id":101,"name":"production","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","protection_rules":[],"deployment_branch_policy":null},
         {"id":102,"name":"staging","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","protection_rules":[],"deployment_branch_policy":null}]}]
        """
        let apiReads = [
            "user/memberships/orgs/\(organization)": #"{"state":"active","role":"admin"}"#,
            "user/memberships/orgs/\(memberOrganization)": #"{"state":"active","role":"member"}"#,
            "repos/\(fullName)/environments?per_page=100": environments,
        ]
        runner.respond(argumentsPrefix: ["api"]) { invocation in
            guard let path = invocation.arguments.last, let body = apiReads[path] else {
                return .failure(exitCode: FakeCommandRunner.unmatchedExitCode, stderr: FakeCommandRunner.unmatchedStderr)
            }
            return .success(body)
        }
        let variables: [String?: String] = [nil: "BASE_URL", "production": "REGION", "staging": "MODE"]
        runner.respond(argumentsPrefix: ["variable", "list", "--repo=\(fullName)"]) { invocation in
            let environment = invocation.arguments.first { $0.hasPrefix("--env=") }.map { String($0.dropFirst("--env=".count)) }
            guard let name = variables[environment] else { return .success("[]") }
            return .success(#"[{"createdAt":"2026-09-01T08:00:00Z","name":"\#(name)","updatedAt":"2026-09-01T08:00:00Z","value":"ui-test"}]"#)
        }
        runner.stub(argumentsPrefix: ["secret", "list", "--repo=\(fullName)"], with: .success("[]"))
        runner.stub(argumentsPrefix: ["secret", "list", "--org=\(organization)"], with: .success(organizationSecrets))
        runner.stub(argumentsPrefix: ["variable", "list", "--org=\(organization)"], with: .success(organizationVariables))
    }

    /// example-org's own items: one secret for every repository, one for 3 selected ones, and a
    /// variable for private and internal repositories.
    static let organizationSecrets = """
    [{"name":"NPM_TOKEN","numSelectedRepos":0,"updatedAt":"2026-08-02T10:00:00Z","visibility":"all"},
     {"name":"STRIPE_KEY","numSelectedRepos":3,"updatedAt":"2026-10-12T10:00:00Z","visibility":"selected"}]
    """
    static let organizationVariables = """
    [{"createdAt":"2026-08-01T10:00:00Z","name":"REGION","numSelectedRepos":0,"updatedAt":"2026-08-02T10:00:00Z","value":"ui-test","visibility":"private"}]
    """
}

/// The scripted `az` and Key Vault of the UI-testing host (B8b2): one signed-in subscription
/// with one vault holding one secret. Reads only; no write is scripted.
enum UITestAzure {
    static let vault = "kv-example-prod"
    static let subscription = FakeAzureOutput.Subscription(
        id: FakeAzureOutput.syntheticID(0x01),
        name: "Example Production",
        tenantID: FakeAzureOutput.syntheticID(0xA1),
        isDefault: true
    )

    static func stub(on runner: FakeCommandRunner) {
        runner.stub(argumentsPrefix: ["account", "list"], with: .success(FakeAzureOutput.accountList([subscription])))
        runner.stub(argumentsPrefix: ["keyvault", "list"], with: .success(FakeAzureOutput.keyVaultList([vault], subscriptionID: subscription.id)))
        runner.stub(argumentsPrefix: ["account", "get-access-token"], with: .success(FakeAzureOutput.accessToken(expiresOn: .distantFuture)))
    }

    static func makeTransport() -> FakeHTTPTransport {
        let transport = FakeHTTPTransport()
        transport.stubKeyVault(vault, secrets: ["DATABASE-URL": "ui-test"])
        return transport
    }
}

extension AppContainer {
    /// A vault on disk under `root`, the scripted gh, an ad-hoc build (so onboarding has no Touch
    /// ID step) and in-memory preferences, over ``sandboxed(mode:session:data:capabilities:preferences:ghStatusProbe:clock:)``:
    /// nothing outside `root` is read or written, no process is spawned and no network is used.
    static func uiTest(root: URL) throws -> AppContainer {
        let clock = SystemClock()
        let session = try VaultSession.openOnDisk(
            directory: root.appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("FX Vault UI Test", isDirectory: true)
        )
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let ghPath = try UITestGitHub.installPlaceholder(in: bin)
        let capabilities = FakeBuildCapabilities()
        capabilities.accessGroup = nil
        let preferences = PreferencesManager(store: InMemoryPreferencesStore())
        preferences.ghPathOverride = ghPath
        return try sandboxed(
            mode: .uiTest(root: root),
            session: session,
            data: VaultDataComponents.makeOffline(
                session: session,
                runner: UITestGitHub.makeRunner(ghPath: ghPath, bin: bin),
                clock: clock,
                sandbox: root.appendingPathComponent("sandbox", isDirectory: true),
                transport: UITestAzure.makeTransport()
            ),
            capabilities: capabilities,
            preferences: preferences,
            ghStatusProbe: { GitHubEnvironmentStatusProbe(github: $0.github, preferences: preferences) },
            clock: clock
        )
    }
}
#endif
