import DestinationKit
import Foundation
import GitHubKit
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Destinations against a real Key Vault (v0.8.0), for a manual check on a developer Mac. Never
/// enabled in CI. Runs only with `FXV_LIVE_DEST_KEYVAULT=<vault name>` (optional
/// `FXV_LIVE_DEST_TENANT`), with the Azure CLI signed in and allowed to get, set, list, delete and
/// recover secrets.
///
/// Use a throwaway vault: the suite writes, changes and deletes names starting with
/// `FXV_E2E_` and leaves them deleted (Key Vault: soft-deleted). Values are random and never
/// printed; assertions compare them in memory.
@Suite("Live destinations (opt-in)", .serialized)
struct LiveDestinationTests {
    static let environment = ProcessInfo.processInfo.environment

    struct Stack {
        let harness: ConfigHarness
        let destinations: DestinationRepository
        let sync: DestinationSyncRepository
        let factory: DestinationRemoteFactory
        let repo: RepoModel
    }

    private static func stack() async throws -> Stack {
        let harness = try await ConfigHarness.make()
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("fxv-live-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let runner = ProcessRunner()
        let identity = ProcessIdentityModel.current()
        let workingDirectory = try EmptyWorkingDirectory.prepare(in: workspace)
        let shell = try await ShellEnvironmentResolver(runner: runner, identity: identity, workingDirectory: workingDirectory).resolve()
        let tokens = AzureCLITokenProvider(runner: runner, identity: identity, shell: shell, workingDirectory: workingDirectory, clock: SystemClock())
        let factory = DestinationRemoteFactory(transport: URLSessionTransport(), azureTokens: tokens, clock: SystemClock())
        return Stack(
            harness: harness,
            destinations: DestinationRepository(session: harness.session, clock: SystemClock()),
            sync: DestinationSyncRepository(session: harness.session, remotes: LiveDestinationRemoteProvider(factory: factory), clock: SystemClock()),
            factory: factory,
            repo: try harness.seedRepository()
        )
    }

    private static func randomValue() -> String {
        "fxv-e2e-" + (0..<4).map { _ in UUID().uuidString.lowercased() }.joined()
    }

    private static func reveal(_ stack: Stack, _ id: ConfigItemID) throws -> String? {
        let value = try stack.destinations.reveal(id)
        defer { value.wipe() }
        return value.utf8String()
    }

    private static func item(_ stack: Stack, _ destination: DestinationID, _ name: String) throws -> DestinationItemModel {
        try #require(try stack.destinations.items(destinationID: destination).first { $0.name == name && !$0.isDeleted })
    }

    // MARK: - Azure CLI token (no vault access)

    /// `FXV_LIVE_DEST_AZ_TOKEN=1`: the real locator, environment allowlist and parser get a Key
    /// Vault token from the signed-in `az`. No vault is contacted.
    @Test(.enabled(if: environment["FXV_LIVE_DEST_AZ_TOKEN"] == "1"))
    func azureCLIGivesAKeyVaultToken() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("fxv-live-az-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let runner = ProcessRunner()
        let identity = ProcessIdentityModel.current()
        let workingDirectory = try EmptyWorkingDirectory.prepare(in: workspace)
        let shell = try await ShellEnvironmentResolver(runner: runner, identity: identity, workingDirectory: workingDirectory).resolve()
        let provider = AzureCLITokenProvider(runner: runner, identity: identity, shell: shell, workingDirectory: workingDirectory, clock: SystemClock())
        let token = try await provider.token(tenantID: nil)
        #expect(token.count > 0)
        token.wipe()
        // A second call is served from the cache (no second az run needed to pass).
        let cached = try await provider.token(tenantID: nil)
        #expect(cached.count > 0)
    }

    // MARK: - Key Vault

    @Test(.enabled(if: environment["FXV_LIVE_DEST_KEYVAULT"] != nil))
    func keyVaultRoundTrip() async throws {
        let stack = try await Self.stack()
        let vaultName = try #require(Self.environment["FXV_LIVE_DEST_KEYVAULT"])
        let target = DestinationTargetModel.azureKeyVault(vaultName: vaultName, tenantID: Self.environment["FXV_LIVE_DEST_TENANT"])
        let destination = try stack.destinations.createDestination(repositoryID: stack.repo.id, target: target, stage: "production")
        _ = try await stack.sync.importRemote(destinationID: destination)

        // Add: one plain value, one with characters JSON must escape.
        let alpha = Self.randomValue()
        let beta = "line one\nline \"two\" ✓ \\ \(Self.randomValue())"
        try stack.destinations.addItem(destinationID: destination, kind: .secret, name: "FXV_E2E_ALPHA", value: SecretBytes(utf8: alpha))
        try stack.destinations.addItem(destinationID: destination, kind: .variable, name: "FXV_E2E_BETA", value: SecretBytes(utf8: beta))
        var review = await stack.sync.review(repositoryID: stack.repo.id)
        #expect(review.executableCount == 2, "\(review.sections.flatMap(\.blocked))")
        var result = await stack.sync.run(review, includeDeletions: true)
        #expect(result.outcomes.values.allSatisfy { $0 == .done }, "\(result.outcomes)")

        // What Key Vault holds is what was sent.
        let remote = try stack.factory.remote(for: target)
        let listed = try await remote.list()
        let listedAlpha = try #require(listed.first { $0.name == "FXV_E2E_ALPHA" })
        #expect(listedAlpha.remoteName.uppercased() == "FXV-E2E-ALPHA")
        let readAlpha = try await remote.readValue(of: listedAlpha)
        #expect(readAlpha.utf8String() == alpha)
        readAlpha.wipe()
        let listedBeta = try #require(listed.first { $0.name == "FXV_E2E_BETA" })
        let readBeta = try await remote.readValue(of: listedBeta)
        #expect(readBeta.utf8String() == beta)
        readBeta.wipe()
        #expect(try await stack.sync.refresh(destinationID: destination).findings.isEmpty)

        // A teammate changes ALPHA in Key Vault: Refresh finds it, Use Remote brings it.
        let teammate = Self.randomValue()
        _ = try await remote.setValue(SecretBytes(utf8: teammate), name: "FXV_E2E_ALPHA", kind: .secret, existing: listedAlpha)
        let refresh = try await stack.sync.refresh(destinationID: destination)
        #expect(refresh.findings.map(\.kind) == [.remoteChanged])
        try await stack.sync.resolve(refresh.findings, choice: .useRemote, destinationID: destination)
        #expect(try Self.reveal(stack, try Self.item(stack, destination, "FXV_E2E_ALPHA").id) == teammate)

        // Delete BETA (a soft delete), then add it again: Key Vault recovers the name first.
        try stack.destinations.deleteItems([try Self.item(stack, destination, "FXV_E2E_BETA").id])
        result = await stack.sync.run(await stack.sync.review(repositoryID: stack.repo.id), includeDeletions: true)
        #expect(result.outcomes.values.allSatisfy { $0 == .done }, "\(result.outcomes)")
        #expect(try await remote.list().contains { $0.name == "FXV_E2E_BETA" } == false)
        let again = Self.randomValue()
        try stack.destinations.addItem(destinationID: destination, kind: .secret, name: "FXV_E2E_BETA", value: SecretBytes(utf8: again))
        result = await stack.sync.run(await stack.sync.review(repositoryID: stack.repo.id), includeDeletions: true)
        #expect(result.outcomes.values.allSatisfy { $0 == .done || $0 == .unconfirmed }, "\(result.outcomes)")
        let recovered = try #require(try await remote.list().first { $0.name == "FXV_E2E_BETA" })
        let readAgain = try await remote.readValue(of: recovered)
        #expect(readAgain.utf8String() == again)
        readAgain.wipe()

        // Clean up: both deleted (soft-deleted in Key Vault).
        let ids = try stack.destinations.items(destinationID: destination).filter { $0.name.hasPrefix("FXV_E2E_") && !$0.isDeleted }.map(\.id)
        try stack.destinations.deleteItems(ids)
        review = await stack.sync.review(repositoryID: stack.repo.id)
        result = await stack.sync.run(review, includeDeletions: true)
        #expect(result.failedCount == 0, "\(result.outcomes)")
    }
}
