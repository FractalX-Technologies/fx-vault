import DestinationKit
import Foundation
import GitHubKit
import VaultCore

/// Azure › subscription › vault for Connect Azure and the sidebar (1.0, B8): read-only `az`
/// listings through ``AzureCLIDiscovery``. Stores nothing and needs no keys, so it also works
/// while locked; the vaults a user picks become destinations through ``DestinationRepository``.
public struct AzureDiscoveryRepository: Sendable {
    private let cli: ShellResolvingAzureCLI

    public init(
        github: GitHubEnvironmentRepository,
        runner: any CommandRunning,
        identity: ProcessIdentityModel,
        workingDirectory: URL,
        fileInspector: any GHFileInspecting = SystemGHFileInspector()
    ) {
        cli = ShellResolvingAzureCLI(
            github: github,
            runner: runner,
            identity: identity,
            workingDirectory: workingDirectory,
            fileInspector: fileInspector
        )
    }

    /// See ``AzureCLIDiscovery/subscriptions()``.
    public func subscriptions() async throws(DestinationError) -> [AzureSubscriptionModel] {
        try await discovery().subscriptions()
    }

    /// See ``AzureCLIDiscovery/keyVaults(subscriptionID:)``.
    public func keyVaults(subscriptionID: UUID) async throws(DestinationError) -> [AzureKeyVaultModel] {
        try await discovery().keyVaults(subscriptionID: subscriptionID)
    }

    /// See ``AzureCLIDiscovery/discover()``.
    public func discover() async throws(DestinationError) -> [AzureSubscriptionVaultsModel] {
        try await discovery().discover()
    }

    /// The subscription whose listing holds the vault `name` (any case), in `tenantID` when given:
    /// what a Refresh saves for a Key Vault imported before 1.0 D6c6. Nil when none lists it.
    public func subscription(ofVaultNamed name: String, tenantID: String?) async throws(DestinationError) -> KeyVaultSubscriptionModel? {
        Self.subscription(ofVaultNamed: name, tenantID: tenantID, in: try await discover())
    }

    static func subscription(
        ofVaultNamed name: String,
        tenantID: String?,
        in listed: [AzureSubscriptionVaultsModel]
    ) -> KeyVaultSubscriptionModel? {
        let entry = listed.first { entry in
            guard tenantID == nil || entry.subscription.tenantID.lowercased() == tenantID?.lowercased() else { return false }
            let vaults = (try? entry.vaults.get()) ?? []
            return vaults.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        return entry.map { KeyVaultSubscriptionModel(id: $0.subscription.id, name: $0.subscription.name) }
    }

    private func discovery() async -> AzureCLIDiscovery {
        AzureCLIDiscovery(cli: await cli.resolve())
    }
}
