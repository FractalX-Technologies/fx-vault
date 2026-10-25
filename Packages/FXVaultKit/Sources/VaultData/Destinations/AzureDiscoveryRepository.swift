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

    private func discovery() async -> AzureCLIDiscovery {
        AzureCLIDiscovery(cli: await cli.resolve())
    }
}
