import Foundation
import VaultCore
import VaultData

/// Saves the Azure subscription of a Key Vault of its own imported before 1.0 D6c6, after its
/// Refresh, so the sidebar groups it under Azure › subscription. Never at launch.
final class KeyVaultSubscriptionLookup {
    private let discovery: AzureDiscoveryRepository
    private let destinations: DestinationRepository
    // A vault no subscription lists is not looked up again this session: each lookup runs `az`
    // once per subscription. A failed `az` (signed out) is tried again at the next Refresh.
    private var misses: Set<DestinationID> = []

    init(discovery: AzureDiscoveryRepository, destinations: DestinationRepository) {
        self.discovery = discovery
        self.destinations = destinations
    }

    /// Whether `destination` still needs its subscription looked up.
    func needsLookup(_ destination: DestinationModel) -> Bool {
        guard destination.repositoryID == nil, destination.subscription == nil, !misses.contains(destination.id),
              case .azureKeyVault = destination.target
        else { return false }
        return true
    }

    /// Looks the subscription up and saves it; a failure leaves the vault directly under Azure.
    func fillIfMissing(_ destination: DestinationModel) async {
        guard needsLookup(destination), case .azureKeyVault(let name, let tenantID) = destination.target else { return }
        do {
            guard let subscription = try await discovery.subscription(ofVaultNamed: name, tenantID: tenantID) else {
                misses.insert(destination.id)
                return
            }
            try destinations.setSubscription(subscription, of: destination.id)
        } catch {
            AppLog.ui.error("Key Vault subscription lookup failed")
        }
    }
}
