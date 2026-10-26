import DestinationKit
import Foundation
import GitHubKit
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// Azure discovery from VaultData (1.0, B8): `az` is found through the probed login-shell PATH,
/// or in the fixed folders when the probe fails. Parsing and errors are DestinationKit's tests.
@Suite("AzureDiscoveryRepository")
struct AzureDiscoveryRepositoryTests {
    private static let shellAZ = "/Users/user-a/tools/bin/az"
    private static let fixedAZ = "/usr/local/bin/az"
    private static let subscriptions = #"[{"id":"00000000-0000-0000-0000-000000000001","name":"Example Production","tenantId":"00000000-0000-0000-0000-0000000000a1","state":"Enabled","isDefault":true}]"#
    private static let vaults = #"[{"name":"kv-example-prod","resourceGroup":"rg-example-prod","location":"westeurope","properties":{"vaultUri":"https://kv-example-prod.vault.azure.net/"}}]"#

    private static func repository(runner: FakeCommandRunner, files: FakeGHFileInspector) throws -> AzureDiscoveryRepository {
        let directory = URL(fileURLWithPath: "/nonexistent/fxvault-tests", isDirectory: true)
        let github = GitHubEnvironmentRepository(
            database: try DatabaseFactory.inMemory(),
            runner: runner,
            identity: GHFixtures.identity,
            workingDirectory: GHFixtures.workingDirectory,
            shellPath: "/bin/zsh",
            sshConfigParser: SSHConfigParser(sshDirectory: directory, homeDirectory: directory),
            fileInspector: files
        )
        return AzureDiscoveryRepository(
            github: github,
            runner: runner,
            identity: GHFixtures.identity,
            workingDirectory: GHFixtures.workingDirectory,
            fileInspector: files
        )
    }

    private static func stubAZ(_ runner: FakeCommandRunner) {
        runner.stub(argumentsPrefix: ["account", "list"], with: .success(subscriptions))
        runner.stub(argumentsPrefix: ["keyvault", "list"], with: .success(vaults))
    }

    @Test func runsTheAZOnTheProbedShellPATH() async throws {
        let files = FakeGHFileInspector()
        files.addFolder("/Users/user-a/tools/bin", owner: FakeGHFileInspector.defaultUserID)
        files.addFile(Self.shellAZ, owner: FakeGHFileInspector.defaultUserID)
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["-i", "-l", "-c"], with: .success("__FXV_B__PATH=/Users/user-a/tools/bin:/usr/bin\n\0__FXV_E__"))
        Self.stubAZ(runner)
        let repository = try Self.repository(runner: runner, files: files)

        let tree = try await repository.discover()
        #expect(tree.map(\.subscription.name) == ["Example Production"])
        #expect((try? tree.first?.vaults.get())?.map(\.name) == ["kv-example-prod"])
        let azRuns = runner.invocations.filter { $0.executablePath == Self.shellAZ }
        #expect(azRuns.map { $0.arguments.first } == ["account", "keyvault"])
        #expect(azRuns.allSatisfy { $0.environment["PATH"] == "/Users/user-a/tools/bin:/usr/bin" })
    }

    /// A Key Vault imported before 1.0 D6c6: its Refresh finds the subscription that lists it,
    /// by name in any case, within its tenant when it has one.
    @Test func aVaultIsFoundInTheSubscriptionThatListsIt() async throws {
        let files = FakeGHFileInspector()
        files.addFolder("/Users/user-a/tools/bin", owner: FakeGHFileInspector.defaultUserID)
        files.addFile(Self.shellAZ, owner: FakeGHFileInspector.defaultUserID)
        let runner = FakeCommandRunner()
        runner.stub(argumentsPrefix: ["-i", "-l", "-c"], with: .success("__FXV_B__PATH=/Users/user-a/tools/bin:/usr/bin\n\0__FXV_E__"))
        Self.stubAZ(runner)
        let repository = try Self.repository(runner: runner, files: files)
        let production = KeyVaultSubscriptionModel(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            name: "Example Production"
        )

        #expect(try await repository.subscription(ofVaultNamed: "KV-EXAMPLE-PROD", tenantID: nil) == .found(production))
        let tenant = "00000000-0000-0000-0000-0000000000A1"
        #expect(try await repository.subscription(ofVaultNamed: "kv-example-prod", tenantID: tenant) == .found(production))
        // A tenant without a listed subscription may need its own login.
        #expect(try await repository.subscription(ofVaultNamed: "kv-example-prod", tenantID: "00000000-0000-0000-0000-0000000000b2") == .incomplete)
        #expect(try await repository.subscription(ofVaultNamed: "kv-example-legacy", tenantID: nil) == .notListed)
        #expect(try await repository.subscription(ofVaultNamed: "kv-example-legacy", tenantID: tenant) == .notListed)

        // One subscription's list failing: the vault may be there, so it is not "not listed".
        runner.replaceStub(argumentsPrefix: ["keyvault", "list"], with: .failure(stderr: "ERROR: (AuthorizationFailed) no role"))
        #expect(try await repository.subscription(ofVaultNamed: "kv-example-legacy", tenantID: nil) == .incomplete)
    }

    @Test func aFailedProbeFallsBackToTheFixedFolders() async throws {
        let files = FakeGHFileInspector()
        files.addFolder("/usr/local/bin", owner: FakeGHFileInspector.defaultUserID)
        files.addFile(Self.fixedAZ, owner: FakeGHFileInspector.defaultUserID)
        let runner = FakeCommandRunner()
        Self.stubAZ(runner)
        let repository = try Self.repository(runner: runner, files: files)

        let vaults = try await repository.keyVaults(subscriptionID: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        #expect(vaults.map(\.name) == ["kv-example-prod"])
        #expect(runner.invocations.last?.executablePath == Self.fixedAZ)
        #expect(try await repository.subscriptions().first?.isDefault == true)
    }
}
