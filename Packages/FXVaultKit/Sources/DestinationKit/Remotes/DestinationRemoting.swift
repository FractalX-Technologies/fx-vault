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
    /// Vercel: the variable applies to one git branch of the preview environment.
    case gitBranch
    /// Vercel: the variable also applies to custom environments, which FX Vault does not manage.
    case customEnvironment
    /// The provider's own variable (a Vercel system variable, a Supabase `SUPABASE_` secret).
    case system
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
    /// Key Vault and Supabase: `.secret`. Vercel: `plain` → `.variable`; `encrypted`,
    /// `sensitive` and `secret` → `.secret` (Vercel's `visibility`, when present, decides).
    public let kind: ConfigKind
    /// Vercel: the environment variable id. Nil elsewhere.
    public let remoteRef: String?
    /// Change marker: Key Vault `attributes.updated` (unix seconds), Supabase the value digest,
    /// Vercel `updatedAt` (milliseconds), as text. Nil when the provider sent none.
    public let version: String?
    /// Supabase: the listed value digest, lowercased. Nil elsewhere.
    public let digest: String?
    /// Whether ``DestinationRemoting/readValue(of:)`` can return the value: an enabled Key Vault
    /// secret, a Vercel variable that is not `sensitive` or a system variable. Never Supabase.
    public let isValueReadable: Bool
    /// Vercel: the variable's other standard environments, which share its value. Empty
    /// elsewhere.
    public let otherTargets: [VercelEnvironment]
    public let updatedAt: Date?

    public init(
        remoteName: String,
        name: String?,
        unusableReason: DestinationUnusableReason?,
        kind: ConfigKind,
        remoteRef: String? = nil,
        version: String?,
        digest: String? = nil,
        isValueReadable: Bool,
        otherTargets: [VercelEnvironment] = [],
        updatedAt: Date?
    ) {
        self.remoteName = remoteName
        self.name = name
        self.unusableReason = unusableReason
        self.kind = kind
        self.remoteRef = remoteRef
        self.version = version
        self.digest = digest
        self.isValueReadable = isValueReadable
        self.otherTargets = otherTargets
        self.updatedAt = updatedAt
    }

    /// True when FX Vault can manage the item.
    public var isUsable: Bool {
        unusableReason == nil && name != nil
    }
}

/// What a write left behind (v0.8.0).
public struct RemoteWriteResultModel: Sendable, Hashable {
    /// The new change marker (Key Vault `attributes.updated`, Vercel `updatedAt`), or nil
    /// (Supabase: re-list to read the digest).
    public let version: String?
    /// Vercel: the environment variable id. Nil elsewhere.
    public let remoteRef: String?

    public init(version: String?, remoteRef: String?) {
        self.version = version
        self.remoteRef = remoteRef
    }
}

/// One destination's remote, as VaultData's sync, import and drift use it (v0.8.0).
///
/// Values travel only in request bodies (`SecretBytes`); the caller owns `value` and wipes it.
/// Requests are retried as ``RequestRetry`` describes before an error is thrown.
public protocol DestinationRemoting: Sendable {
    var provider: DestinationProvider { get }

    /// Every item the destination holds, usable or not (``RemoteDestinationItemModel/unusableReason``).
    /// Vercel: only the variables that apply to the destination's environment.
    func list() async throws(DestinationError) -> [RemoteDestinationItemModel]

    /// The value of a listed item. Throws ``DestinationError/invalidRequest(code:)`` with
    /// ``DestinationError/LocalCode/writeOnly`` when ``RemoteDestinationItemModel/isValueReadable``
    /// is false. The caller wipes the result.
    func readValue(of item: RemoteDestinationItemModel) async throws(DestinationError) -> SecretBytes

    /// Creates or updates `name` (an FX Vault name) with `value`.
    ///
    /// `kind` becomes the provider's stored kind (Key Vault and Supabase: secret). `existing` is
    /// the listed item with that name, if any (Vercel updates it by id, keeping a `sensitive`
    /// type; Key Vault writes to its remote name). Key Vault recovers a soft-deleted name first.
    func setValue(
        _ value: SecretBytes,
        name: String,
        kind: ConfigKind,
        existing: RemoteDestinationItemModel?
    ) async throws(DestinationError) -> RemoteWriteResultModel

    /// Deletes a listed item: a soft delete in Key Vault (never a purge); in Vercel, a variable
    /// with ``RemoteDestinationItemModel/otherTargets`` only loses this environment.
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

    /// The remote for `target`.
    ///
    /// - `token` is the Supabase or Vercel personal access token (copied; the caller keeps and
    ///   wipes its own). ``DestinationError/tokenMissing`` when it is nil, empty or not printable
    ///   ASCII for those providers; ignored for Key Vault, which asks `azureTokens`.
    /// - The target is validated first (``DestinationError/invalidInput(_:)``).
    public func remote(for target: DestinationTargetModel, token: SecretBytes?) throws(DestinationError) -> any DestinationRemoting {
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
        case .supabase(let projectRef):
            let client = ProviderHTTPClient(
                provider: .supabase,
                transport: transport,
                clock: clock,
                credential: try .personalToken(token)
            )
            return SupabaseRemote(projectRef: projectRef, client: client)
        case .vercel(let projectID, _, let teamID, let environment):
            let client = ProviderHTTPClient(
                provider: .vercel,
                transport: transport,
                clock: clock,
                credential: try .personalToken(token)
            )
            return VercelRemote(projectID: projectID, teamID: teamID, environment: environment, client: client)
        }
    }
}

/// Checks shared by the three remotes before a write.
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
