import Foundation
import VaultCore

/// Why a listed remote item cannot be managed by FX Vault (v0.8.0, tasks/todo.md R3, R11).
/// Such items are listed with their reason, never dropped.
public enum DestinationUnusableReason: Sendable, Hashable {
    /// The remote name cannot become a valid FX Vault name (GitHub's rules plus the provider's).
    case invalidName(ValidationError)
    /// Key Vault: the secret is disabled.
    case disabled
    /// Key Vault: the secret is managed by Key Vault (it backs a certificate).
    case managed
}

/// One secret or variable as the provider lists it (v0.8.0). Never holds a value.
public struct RemoteDestinationItemModel: Sendable, Hashable {
    /// The name as the provider has it (Key Vault: with dashes).
    public let remoteName: String
    /// FX Vault's name (`DestinationRules.localName(forRemoteName:provider:)`), or nil when the
    /// remote name cannot map to a valid one (then ``unusableReason`` is
    /// ``DestinationUnusableReason/invalidName(_:)``). An item is usable only when
    /// ``unusableReason`` is nil; a disabled or managed secret keeps its name.
    public let name: String?
    public let unusableReason: DestinationUnusableReason?
    /// Key Vault: always `.secret`.
    public let kind: ConfigKind
    /// Change marker: Key Vault `attributes.updated` (unix seconds), as text. Nil when the
    /// provider sent none.
    public let version: String?
    /// Whether ``DestinationRemoting/readValue(of:)`` can return the value: an enabled Key Vault
    /// secret.
    public let isValueReadable: Bool
    public let updatedAt: Date?

    public init(
        remoteName: String,
        name: String?,
        unusableReason: DestinationUnusableReason?,
        kind: ConfigKind,
        version: String?,
        isValueReadable: Bool,
        updatedAt: Date?
    ) {
        self.remoteName = remoteName
        self.name = name
        self.unusableReason = unusableReason
        self.kind = kind
        self.version = version
        self.isValueReadable = isValueReadable
        self.updatedAt = updatedAt
    }

    /// True when FX Vault can manage the item.
    public var isUsable: Bool {
        unusableReason == nil && name != nil
    }
}

/// What a write left behind (v0.8.0).
public struct RemoteWriteResultModel: Sendable, Hashable {
    /// The new change marker (Key Vault `attributes.updated`), or nil.
    public let version: String?

    public init(version: String?) {
        self.version = version
    }
}

/// One destination's remote, as VaultData's sync, import and drift use it (v0.8.0).
///
/// Values travel only in request bodies (`SecretBytes`); the caller owns `value` and wipes it.
/// Requests are retried as ``RequestRetry`` describes before an error is thrown.
public protocol DestinationRemoting: Sendable {
    var provider: DestinationProvider { get }

    /// Every item the destination holds, usable or not (``RemoteDestinationItemModel/unusableReason``).
    func list() async throws(DestinationError) -> [RemoteDestinationItemModel]

    /// The value of a listed item. Throws ``DestinationError/invalidRequest(code:)`` with
    /// ``DestinationError/LocalCode/writeOnly`` when ``RemoteDestinationItemModel/isValueReadable``
    /// is false. The caller wipes the result.
    func readValue(of item: RemoteDestinationItemModel) async throws(DestinationError) -> SecretBytes

    /// Creates or updates `name` (an FX Vault name) with `value`.
    ///
    /// `kind` becomes the provider's stored kind (Key Vault: secret). `existing` is the listed
    /// item with that name, if any (Key Vault writes to its remote name). Key Vault recovers a
    /// soft-deleted name first.
    func setValue(
        _ value: SecretBytes,
        name: String,
        kind: ConfigKind,
        existing: RemoteDestinationItemModel?
    ) async throws(DestinationError) -> RemoteWriteResultModel

    /// Deletes a listed item: a soft delete in Key Vault (never a purge).
    /// Throws ``DestinationError/notFound`` when it is already gone.
    func delete(_ item: RemoteDestinationItemModel) async throws(DestinationError)
}

/// Builds the remote of a destination (v0.8.0).
public struct DestinationRemoteFactory: Sendable {
    private let transport: any HTTPTransporting
    private let azureTokens: any AccessTokenProviding
    private let clock: any VaultClock

    public init(transport: any HTTPTransporting, azureTokens: any AccessTokenProviding, clock: any VaultClock) {
        self.transport = transport
        self.azureTokens = azureTokens
        self.clock = clock
    }

    /// The remote for `target`, validated first (``DestinationError/invalidInput(_:)``). Key Vault
    /// asks `azureTokens` for its access token.
    public func remote(for target: DestinationTargetModel) throws(DestinationError) -> any DestinationRemoting {
        let validated: DestinationTargetModel
        do {
            validated = try DestinationRules.validate(target)
        } catch {
            throw .invalidInput(error)
        }
        switch validated {
        case .azureKeyVault(let vaultName, let tenantID):
            let client = ProviderHTTPClient(
                provider: .azureKeyVault,
                transport: transport,
                clock: clock,
                credential: .azure(azureTokens, tenantID: tenantID)
            )
            return AzureKeyVaultRemote(vaultName: vaultName, client: client, clock: clock)
        }
    }
}

/// Checks a remote runs before a write.
enum RemoteWriteCheck {
    /// Validates `name` for `provider` with the provider's stored kind and checks the value's
    /// size. Returns the stored kind.
    static func validate(
        name: String,
        kind: ConfigKind,
        value: SecretBytes,
        provider: DestinationProvider
    ) throws(DestinationError) -> ConfigKind {
        let storedKind = provider.storedKind(for: kind)
        do {
            try DestinationRules.validate(name, kind: storedKind, provider: provider)
        } catch {
            throw .invalidInput(error)
        }
        guard value.count <= DestinationRules.maxValueBytes(for: provider) else { throw .valueTooLarge }
        return storedKind
    }

    /// Throws ``DestinationError/invalidRequest(code:)`` with
    /// ``DestinationError/LocalCode/writeOnly`` unless `item` can be read.
    static func requireReadable(_ item: RemoteDestinationItemModel) throws(DestinationError) {
        guard item.isValueReadable else { throw .invalidRequest(code: DestinationError.LocalCode.writeOnly) }
    }
}
