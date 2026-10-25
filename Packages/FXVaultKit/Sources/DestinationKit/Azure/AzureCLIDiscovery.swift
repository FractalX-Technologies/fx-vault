import Foundation
import VaultCore

/// A subscription `az account list` knows (1.0, B8). Never carries the signed-in user.
public struct AzureSubscriptionModel: Sendable, Hashable, Identifiable {
    /// Typed so it can go back to `az` as `--subscription` without ever becoming a flag.
    public let id: UUID
    public let name: String
    /// Lowercased UUID text, the form `DestinationTargetModel.azureKeyVault` takes.
    public let tenantID: String
    public let state: AzureSubscriptionState
    public let isDefault: Bool

    public init(id: UUID, name: String, tenantID: String, state: AzureSubscriptionState, isDefault: Bool) {
        self.id = id
        self.name = name
        self.tenantID = tenantID
        self.state = state
        self.isDefault = isDefault
    }
}

/// Azure's subscription states; `other` keeps a state a newer `az` reports readable.
public enum AzureSubscriptionState: Sendable, Hashable {
    case enabled
    case warned
    case pastDue
    case disabled
    case deleted
    case other

    init(listed: String) {
        switch listed.lowercased() {
        case "enabled": self = .enabled
        case "warned": self = .warned
        case "pastdue": self = .pastDue
        case "disabled": self = .disabled
        case "deleted": self = .deleted
        default: self = .other
        }
    }
}

/// A Key Vault `az keyvault list` returned (1.0, B8).
public struct AzureKeyVaultModel: Sendable, Hashable, Identifiable {
    public var id: String { name.lowercased() }
    /// Passes `DestinationRules.isValidKeyVaultName`.
    public let name: String
    public let resourceGroup: String
    public let location: String
    /// The listed `properties.vaultUri` when it is this vault's own allowlisted host; nil when
    /// `az` gave none or another cloud's (FX Vault reaches a vault only through its name).
    public let vaultURI: URL?

    public init(name: String, resourceGroup: String, location: String, vaultURI: URL?) {
        self.name = name
        self.resourceGroup = resourceGroup
        self.location = location
        self.vaultURI = vaultURI
    }
}

/// One subscription and its vaults, or why they could not be listed.
public struct AzureSubscriptionVaultsModel: Sendable, Hashable {
    public let subscription: AzureSubscriptionModel
    public let vaults: Result<[AzureKeyVaultModel], DestinationError>

    public init(subscription: AzureSubscriptionModel, vaults: Result<[AzureKeyVaultModel], DestinationError>) {
        self.subscription = subscription
        self.vaults = vaults
    }
}

/// The Azure tree of the sidebar and Connect Azure (1.0, B8): subscriptions from
/// `az account list`, then each one's vaults from `az keyvault list`, read-only, through
/// ``AzureCLIRunner``. Output is read with the secret JSON scanner and wiped.
public struct AzureCLIDiscovery: Sendable {
    static let accountListArguments = ["account", "list"]
    /// `--resource-type vault` leaves out Managed HSMs, which have no `vaultUri` and no secrets.
    static let keyVaultListArguments = ["keyvault", "list", "--resource-type", "vault"]
    static let subscriptionFlag = "--subscription"

    private static let idField = "id"
    private static let nameField = "name"
    private static let tenantField = "tenantId"
    private static let stateField = "state"
    private static let defaultField = "isDefault"
    private static let resourceGroupField = "resourceGroup"
    private static let locationField = "location"
    private static let propertiesField = "properties"
    private static let vaultURIField = "vaultUri"

    private let cli: AzureCLIRunner

    public init(cli: AzureCLIRunner) {
        self.cli = cli
    }

    /// Every subscription, one entry per id (the default one wins). An empty list is
    /// ``DestinationError/azNotSignedIn``: `az` answers `[]` with exit 0 when nobody is signed
    /// in, and FX Vault passes `AZURE_CORE_ONLY_SHOW_ERRORS`, which hides its hint.
    public func subscriptions() async throws(DestinationError) -> [AzureSubscriptionModel] {
        let stdout = try await cli.run(Self.accountListArguments + AzureCLIRunner.outputArguments, timeout: Timeouts.azList)
        defer { stdout.wipe() }
        let subscriptions = try Self.parseSubscriptions(stdout: stdout)
        guard !subscriptions.isEmpty else { throw .azNotSignedIn }
        return subscriptions
    }

    /// The vaults of one subscription.
    public func keyVaults(subscriptionID: UUID) async throws(DestinationError) -> [AzureKeyVaultModel] {
        let stdout = try await cli.run(Self.arguments(subscriptionID: subscriptionID), timeout: Timeouts.azList)
        defer { stdout.wipe() }
        return try Self.parseKeyVaults(stdout: stdout)
    }

    /// Subscriptions with their vaults. One subscription's failure (a tenant that needs its own
    /// `az login`, no role) stays on that entry; only listing the subscriptions or cancelling
    /// fails the whole call. Runs one `az` at a time: concurrent runs race on `az`'s token cache.
    public func discover() async throws(DestinationError) -> [AzureSubscriptionVaultsModel] {
        var result: [AzureSubscriptionVaultsModel] = []
        for subscription in try await subscriptions() {
            let vaults: Result<[AzureKeyVaultModel], DestinationError>
            do {
                vaults = .success(try await keyVaults(subscriptionID: subscription.id))
            } catch .cancelled {
                throw .cancelled
            } catch {
                vaults = .failure(error)
            }
            result.append(AzureSubscriptionVaultsModel(subscription: subscription, vaults: vaults))
        }
        return result
    }

    static func arguments(subscriptionID: UUID) -> [String] {
        keyVaultListArguments + [subscriptionFlag, subscriptionID.uuidString.lowercased()] + AzureCLIRunner.outputArguments
    }

    /// Any entry without a UUID id and tenant, a name, a state or `isDefault` makes the whole
    /// answer ``DestinationError/decoding``: Azure guarantees them, so their absence means the
    /// output is not what FX Vault expects.
    static func parseSubscriptions(stdout: SecretBytes) throws(DestinationError) -> [AzureSubscriptionModel] {
        guard let entries = try SecretJSONDocument(parsing: stdout).elements() else { throw .decoding }
        var result: [AzureSubscriptionModel] = []
        for entry in entries {
            guard let id = entry.string(.key(idField)).flatMap(UUID.init(uuidString:)),
                  let tenant = entry.string(.key(tenantField)).flatMap(UUID.init(uuidString:)),
                  let name = entry.string(.key(nameField)),
                  let state = entry.string(.key(stateField)),
                  let isDefault = entry.bool(.key(defaultField))
            else { throw .decoding }
            let subscription = AzureSubscriptionModel(
                id: id,
                name: name,
                tenantID: tenant.uuidString.lowercased(),
                state: AzureSubscriptionState(listed: state),
                isDefault: isDefault
            )
            if let index = result.firstIndex(where: { $0.id == id }) {
                if isDefault { result[index] = subscription }
            } else {
                result.append(subscription)
            }
        }
        return result
    }

    /// A name that breaks Azure's vault rules, or a missing resource group or location, makes
    /// the answer ``DestinationError/decoding`` (the name later becomes a host).
    static func parseKeyVaults(stdout: SecretBytes) throws(DestinationError) -> [AzureKeyVaultModel] {
        guard let entries = try SecretJSONDocument(parsing: stdout).elements() else { throw .decoding }
        var result: [AzureKeyVaultModel] = []
        for entry in entries {
            guard let name = entry.string(.key(nameField)), DestinationRules.isValidKeyVaultName(name),
                  let resourceGroup = entry.string(.key(resourceGroupField)),
                  let location = entry.string(.key(locationField))
            else { throw .decoding }
            let listedURI = entry.string(.key(propertiesField), .key(vaultURIField)).flatMap { URL(string: $0) }
            let vaultURI = listedURI.flatMap { isOwnHost($0, vaultName: name) ? $0 : nil }
            result.append(AzureKeyVaultModel(name: name, resourceGroup: resourceGroup, location: location, vaultURI: vaultURI))
        }
        return result
    }

    private static func isOwnHost(_ url: URL, vaultName: String) -> Bool {
        DestinationHostPolicy.isAllowed(url) && url.host?.lowercased() == DestinationHostPolicy.keyVaultHost(vaultName: vaultName)
    }
}
