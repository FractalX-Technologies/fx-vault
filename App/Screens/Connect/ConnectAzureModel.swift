import DestinationKit
import Foundation
import GitHubKit
import Observation
import VaultCore
import VaultData

/// Board ConnectAzure (1.0): the `az` requirements, then each subscription with its Key Vaults to
/// choose from. A chosen vault becomes a Key Vault of its own (no repository) and is imported
/// with its values. Nothing is written to Azure.
@Observable
final class ConnectAzureModel {
    /// What stands between FX Vault and the vault list.
    enum Requirement: Equatable {
        case ready
        /// No `az`: install it (Run when Homebrew is trusted).
        case notInstalled
        /// An `az` another user can change: FX Vault does not run it.
        case untrusted(path: String)
        /// `az login` first (interactive, so Copy only).
        case notSignedIn
        case failed(ErrorPresentationModel)
    }

    struct Vault: Identifiable, Hashable {
        let name: String
        let location: String
        let tenantID: String
        /// Saved with the vault: the sidebar groups Azure › subscription › vault (1.0 D6c6).
        let subscription: KeyVaultSubscriptionModel

        var id: String {
            name.lowercased()
        }
    }

    struct Subscription: Identifiable, Hashable {
        let id: UUID
        let name: String
        let vaults: [Vault]
        /// The vault list failed for this subscription only (no access, for example).
        let failure: String?
    }

    /// One imported vault's totals.
    struct ImportResult: Equatable {
        var vaultCount = 0
        var secretCount = 0
        var failedNames: [String] = []
    }

    static let installCommand = SetupCommand.installAzureCLI.displayText
    static let loginCommand = DestinationSyncCopy.azLoginCommand

    private(set) var requirement: Requirement?
    private(set) var subscriptions: [Subscription] = []
    var selection: Set<Vault.ID> = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var copiedCommand: String?
    let runs: SetupCommandRunState

    @ObservationIgnored private let app: AppViewModel

    init(app: AppViewModel) {
        self.app = app
        runs = SetupCommandRunState(github: app.container.data.github)
    }

    private var data: VaultDataComponents {
        app.container.data
    }

    var selectedVaults: [Vault] {
        subscriptions.flatMap(\.vaults).filter { selection.contains($0.id) }
    }

    /// The commands the requirement asks for, in order.
    var commands: [String] {
        switch requirement {
        case .notInstalled, .untrusted: [Self.installCommand, Self.loginCommand]
        case .notSignedIn: [Self.loginCommand]
        case .ready, .failed, nil: []
        }
    }

    // MARK: - Loading

    /// Lists the subscriptions and their vaults, every vault checked. Disabled and deleted
    /// subscriptions are left out: their vaults cannot be read.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        copiedCommand = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        await runs.loadAvailability()
        let listed: [AzureSubscriptionVaultsModel]
        do {
            listed = try await data.azureDiscovery.discover()
        } catch {
            subscriptions = []
            selection = []
            requirement = Self.requirement(for: error)
            return
        }
        requirement = .ready
        subscriptions = listed
            .filter { $0.subscription.state != .disabled && $0.subscription.state != .deleted }
            .map { entry in
                let tenantID = entry.subscription.tenantID
                let subscription = KeyVaultSubscriptionModel(id: entry.subscription.id, name: entry.subscription.name)
                switch entry.vaults {
                case .success(let vaults):
                    return Subscription(
                        id: entry.subscription.id,
                        name: entry.subscription.name,
                        vaults: vaults.map {
                            Vault(name: $0.name, location: $0.location, tenantID: tenantID, subscription: subscription)
                        },
                        failure: nil
                    )
                case .failure(let error):
                    return Subscription(
                        id: entry.subscription.id,
                        name: entry.subscription.name,
                        vaults: [],
                        failure: error.localizedMessage(provider: .azureKeyVault)
                    )
                }
            }
        selection = Set(subscriptions.flatMap(\.vaults).map(\.id))
    }

    static func requirement(for error: DestinationError) -> Requirement {
        switch error {
        case .azNotInstalled: .notInstalled
        case .azUntrusted(let path): .untrusted(path: path)
        case .azNotSignedIn: .notSignedIn
        default: .failed(ErrorPresentationModel(
            title: String(localized: "connect.azure.failed", defaultValue: "Azure could not be read"),
            message: error.localizedMessage(provider: .azureKeyVault)
        ))
        }
    }

    /// The vault locked: nothing listed stays in memory.
    func reset() {
        subscriptions = []
        selection = []
        requirement = nil
        hasLoaded = false
        copiedCommand = nil
    }

    func toggle(_ vault: Vault) {
        if selection.contains(vault.id) {
            selection.remove(vault.id)
        } else {
            selection.insert(vault.id)
        }
    }

    /// **Run** `brew install azure-cli`, then list again.
    func run(_ command: SetupCommand) async {
        copiedCommand = nil
        if await runs.run(command) {
            await load()
        }
    }

    func copy(_ command: String) {
        app.container.clipboard.copyCommand(command)
        copiedCommand = command
    }

    // MARK: - Import

    /// Adds each chosen vault as a Key Vault of its own (or reuses the one already there) and
    /// imports its secrets with their values. `progress` names the vault being read.
    func importSelected(progress: (String) -> Void) async -> ImportResult {
        var result = ImportResult()
        for vault in selectedVaults {
            guard app.phase == .unlocked else { break }
            progress(vault.name)
            do {
                let id: DestinationID
                if let existing = try existingVault(vault) {
                    id = existing
                    // Only the sidebar's grouping: the import goes on without it.
                    do {
                        try data.destinations.setSubscription(vault.subscription, of: id)
                    } catch {
                        AppLog.ui.error("Key Vault subscription not saved")
                    }
                } else {
                    id = try data.destinations.createDestination(
                        repositoryID: nil,
                        target: .azureKeyVault(vaultName: vault.name, tenantID: vault.tenantID),
                        stage: nil,
                        subscription: vault.subscription
                    )
                }
                let imported = try await data.destinationSync.importRemote(destinationID: id)
                result.vaultCount += 1
                result.secretCount += imported.imported.count
            } catch {
                result.failedNames.append(vault.name)
            }
        }
        return result
    }

    private func existingVault(_ vault: Vault) throws -> DestinationID? {
        let key = DestinationTargetModel.azureKeyVault(vaultName: vault.name, tenantID: vault.tenantID).targetKey
        return try data.destinations.destinations(repositoryID: nil).first { $0.target.targetKey == key }?.id
    }
}
