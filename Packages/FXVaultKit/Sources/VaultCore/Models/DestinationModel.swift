import Foundation

/// A runtime destination's provider (v0.8.0, `destinations.provider`).
///
/// Raw values are stored and never change.
public enum DestinationProvider: String, Sendable, Hashable, Codable, CaseIterable {
    /// One Azure Key Vault, reached with the user's `az login`.
    case azureKeyVault = "azure_keyvault"
    /// One Supabase project's Edge Function secrets, reached with a personal access token.
    case supabase
    /// One Vercel project environment, reached with a personal access token.
    case vercel

    /// Whether the provider stores variables as well as secrets. Key Vault and Supabase hold
    /// secrets only (R3): a variable copied there becomes a secret.
    public var holdsVariables: Bool {
        self == .vercel
    }

    /// Whether the provider can return stored values, so drift can compare values and "Use
    /// Remote" can import them. Supabase returns digests only.
    public var returnsValues: Bool {
        self != .supabase
    }

    /// Whether FX Vault reaches it with a token the user added (a ``ConnectionModel``) rather
    /// than a CLI login.
    public var usesConnection: Bool {
        self != .azureKeyVault
    }

    /// The kind an item takes in this provider: secrets only where ``holdsVariables`` is false.
    public func storedKind(for kind: ConfigKind) -> ConfigKind {
        holdsVariables ? kind : .secret
    }
}

/// A Vercel project environment (the `target` of an environment variable).
///
/// Raw values are Vercel's and are stored. Custom environments are not supported in v0.8 (R11).
public enum VercelEnvironment: String, Sendable, Hashable, Codable, CaseIterable {
    case production
    case preview
    case development
}

/// Where one destination points (`destinations.target_key` and `settings_json`).
public enum DestinationTargetModel: Sendable, Hashable {
    /// One Key Vault by name. `tenantID` asks `az` for a token of that tenant; nil uses the
    /// account's default tenant.
    case azureKeyVault(vaultName: String, tenantID: String?)
    /// One Supabase project by reference (20 lowercase letters).
    case supabase(projectRef: String)
    /// One Vercel project environment. `teamID` is nil for a personal account.
    case vercel(projectID: String, projectName: String, teamID: String?, environment: VercelEnvironment)

    public var provider: DestinationProvider {
        switch self {
        case .azureKeyVault: .azureKeyVault
        case .supabase: .supabase
        case .vercel: .vercel
        }
    }

    /// The identity of the remote place, unique per repository (`destinations.target_key`):
    /// `kv|<vault>`, `sb|<ref>` or `vc|<team or ->|<project id>|<environment>`, lowercase.
    public var targetKey: String {
        switch self {
        case .azureKeyVault(let vaultName, _):
            "kv|\(vaultName.lowercased())"
        case .supabase(let projectRef):
            "sb|\(projectRef.lowercased())"
        case .vercel(let projectID, _, let teamID, let environment):
            "vc|\(teamID?.lowercased() ?? "-")|\(projectID.lowercased())|\(environment.rawValue)"
        }
    }

    /// The short label the sidebar and the review show: the vault name, the project reference,
    /// or "project · environment".
    public var displayName: String {
        switch self {
        case .azureKeyVault(let vaultName, _): vaultName
        case .supabase(let projectRef): projectRef
        case .vercel(_, let projectName, _, let environment): "\(projectName) · \(environment.rawValue)"
        }
    }
}

/// A place outside GitHub that one vault repository's code reads at runtime (v0.8.0,
/// `destinations` row, tasks/todo.md R1).
///
/// Removing a destination from FX Vault never deletes anything remotely.
public struct DestinationModel: Sendable, Hashable, Identifiable {
    public var id: DestinationID
    public var repositoryID: RepoID
    public var target: DestinationTargetModel
    /// The stage this destination serves (`production`, `staging`, …;
    /// ``EnvironmentNameValidator`` rules), or nil.
    public var stage: String?
    /// The token FX Vault uses for Supabase and Vercel; nil for Key Vault.
    public var connectionID: ConnectionID?
    /// The order inside the repository's RUNTIME section (ascending).
    public var sortOrder: Int
    /// When the remote was last listed (import, Refresh or Sync).
    public var lastRefreshedAt: Date?
    /// Live items by kind and pending changes, set by the observation.
    public var secretCount: Int
    public var variableCount: Int
    public var pendingCount: Int
    public var valueMissingCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: DestinationID = DestinationID(),
        repositoryID: RepoID,
        target: DestinationTargetModel,
        stage: String?,
        connectionID: ConnectionID?,
        sortOrder: Int,
        lastRefreshedAt: Date? = nil,
        secretCount: Int = 0,
        variableCount: Int = 0,
        pendingCount: Int = 0,
        valueMissingCount: Int = 0,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.target = target
        self.stage = stage
        self.connectionID = connectionID
        self.sortOrder = sortOrder
        self.lastRefreshedAt = lastRefreshedAt
        self.secretCount = secretCount
        self.variableCount = variableCount
        self.pendingCount = pendingCount
        self.valueMissingCount = valueMissingCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var provider: DestinationProvider {
        target.provider
    }

    /// Secrets and variables together.
    public var itemCount: Int {
        secretCount + variableCount
    }

    /// `stage` case-folded (``EnvironmentNameValidator/foldKey(_:)``), or nil.
    public var stageKey: String? {
        stage.map(EnvironmentNameValidator.foldKey)
    }
}

/// A secret or variable of a destination (v0.8.0, `destination_items` row), without its value.
///
/// Its id is a ``ConfigItemID``, as for folder items: copy and paste, linked copies and the
/// detail table treat it like any other item, and the three item tables never share an id.
public struct DestinationItemModel: Sendable, Hashable, Identifiable {
    public var id: ConfigItemID
    public var destinationID: DestinationID
    public var kind: ConfigKind
    /// Uppercase (``GitHubNameValidator``), so it can be copied anywhere.
    public var name: String
    /// Whether a local value exists. A write-only remote value (Supabase, a Vercel sensitive
    /// variable) imports as ``ConfigValueState/missing``.
    public var valueState: ConfigValueState
    /// The name the remote has (in FX Vault's form), or nil if never pushed.
    public var syncedName: String?
    /// Tombstone: pending deletion remotely.
    public var isDeleted: Bool
    /// Re-sent on the next Sync (Push on Next Sync, "Keep Mine").
    public var forcePush: Bool
    public var verifyState: VerifyState
    /// The user confirmed that this value is meant to be public (R10, "Mark as Public").
    public var isPublicAllowed: Bool
    public var syncStatus: ConfigSyncStatus
    public var linkID: ItemLinkID?
    /// Live members of ``linkID`` across repositories, folders and destinations; 0 when not
    /// linked.
    public var linkCount: Int
    /// The share file this row is held under (v0.9.0, `share_hold`): Sync leaves it out until its
    /// From Files review includes the file. Nil when the row is not held.
    public var heldBy: SharePackageID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ConfigItemID = ConfigItemID(),
        destinationID: DestinationID,
        kind: ConfigKind,
        name: String,
        valueState: ConfigValueState,
        syncedName: String? = nil,
        isDeleted: Bool = false,
        forcePush: Bool = false,
        verifyState: VerifyState = .verified,
        isPublicAllowed: Bool = false,
        syncStatus: ConfigSyncStatus,
        linkID: ItemLinkID? = nil,
        linkCount: Int = 0,
        heldBy: SharePackageID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.destinationID = destinationID
        self.kind = kind
        self.name = name
        self.valueState = valueState
        self.syncedName = syncedName
        self.isDeleted = isDeleted
        self.forcePush = forcePush
        self.verifyState = verifyState
        self.isPublicAllowed = isPublicAllowed
        self.syncStatus = syncStatus
        self.linkID = linkID
        self.linkCount = linkCount
        self.heldBy = heldBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True while the row waits for Sync's From Files review (v0.9.0).
    public var isHeld: Bool {
        heldBy != nil
    }

    public var isLinked: Bool {
        linkID != nil && linkCount > 1
    }

    public var isSynced: Bool {
        syncedName != nil
    }

    public var hasValue: Bool {
        valueState == .present
    }

    public var nameKey: String {
        GitHubNameValidator.foldKey(name)
    }
}

/// A token FX Vault keeps to reach Supabase or Vercel (v0.8.0, `provider_connections` row),
/// without the token.
public struct ConnectionModel: Sendable, Hashable, Identifiable {
    public var id: ConnectionID
    /// ``DestinationProvider/supabase`` or ``DestinationProvider/vercel``.
    public var provider: DestinationProvider
    /// The user's name for it ("FractalX Vercel"), ``FolderNameValidator`` rules.
    public var label: String
    /// Who the token belongs to, as the provider reported it when it was checked (a Vercel
    /// username, a Supabase organization count), or nil. Never the token.
    public var accountHint: String?
    public var lastValidatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ConnectionID = ConnectionID(),
        provider: DestinationProvider,
        label: String,
        accountHint: String? = nil,
        lastValidatedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.accountHint = accountHint
        self.lastValidatedAt = lastValidatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
