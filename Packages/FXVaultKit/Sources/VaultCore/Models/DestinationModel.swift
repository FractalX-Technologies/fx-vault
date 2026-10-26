import Foundation

/// A runtime destination's provider (v0.8.0, `destinations.provider`).
///
/// Raw values are stored and never change. 1.0 keeps Azure Key Vault only: migration
/// `v16_drop_runtime_providers` deletes the Supabase and Vercel destinations 0.8 and 0.9 wrote.
public enum DestinationProvider: String, Sendable, Hashable, Codable, CaseIterable {
    /// One Azure Key Vault, reached with the user's `az login`.
    case azureKeyVault = "azure_keyvault"

    /// The kind an item takes in this provider: Key Vault holds secrets only (R3), so a variable
    /// copied there becomes a secret.
    public func storedKind(for kind: ConfigKind) -> ConfigKind {
        .secret
    }
}

/// Where one destination points (`destinations.target_key` and `settings_json`).
public enum DestinationTargetModel: Sendable, Hashable {
    /// One Key Vault by name. `tenantID` asks `az` for a token of that tenant; nil uses the
    /// account's default tenant.
    case azureKeyVault(vaultName: String, tenantID: String?)

    public var provider: DestinationProvider {
        switch self {
        case .azureKeyVault: .azureKeyVault
        }
    }

    /// The identity of the remote place, unique per repository (`destinations.target_key`):
    /// `kv|<vault>`, lowercase.
    public var targetKey: String {
        switch self {
        case .azureKeyVault(let vaultName, _):
            "kv|\(vaultName.lowercased())"
        }
    }

    /// The short label the sidebar and the review show: the vault name.
    public var displayName: String {
        switch self {
        case .azureKeyVault(let vaultName, _): vaultName
        }
    }
}

/// A place outside GitHub that one vault repository's code reads at runtime (v0.8.0,
/// `destinations` row, tasks/todo.md R1), or a Key Vault source of its own (1.0, B8b).
///
/// Removing a destination from FX Vault never deletes anything remotely.
public struct DestinationModel: Sendable, Hashable, Identifiable {
    public var id: DestinationID
    /// nil: a Key Vault source of its own, listed beside GitHub rather than under a repository.
    public var repositoryID: RepoID?
    public var target: DestinationTargetModel
    /// The stage this destination serves (`production`, `staging`, …;
    /// ``EnvironmentNameValidator`` rules), or nil.
    public var stage: String?
    /// The order inside the repository's RUNTIME section (ascending).
    public var sortOrder: Int
    /// When the remote was last listed (import, Refresh or Sync).
    public var lastRefreshedAt: Date?
    /// A Key Vault of its own's Azure subscription (1.0 D6c6), nil until Connect Azure or a
    /// Refresh saves it: the sidebar groups Azure › subscription › vault by it.
    public var subscription: KeyVaultSubscriptionModel?
    /// Live items by kind and pending changes, set by the observation.
    public var secretCount: Int
    public var variableCount: Int
    public var pendingCount: Int
    public var valueMissingCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: DestinationID = DestinationID(),
        repositoryID: RepoID?,
        target: DestinationTargetModel,
        stage: String?,
        sortOrder: Int,
        lastRefreshedAt: Date? = nil,
        subscription: KeyVaultSubscriptionModel? = nil,
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
        self.sortOrder = sortOrder
        self.lastRefreshedAt = lastRefreshedAt
        self.subscription = subscription
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
    /// Whether a local value exists.
    public var valueState: ConfigValueState
    /// The name the remote has (in FX Vault's form), or nil if never pushed.
    public var syncedName: String?
    /// Tombstone: pending deletion remotely.
    public var isDeleted: Bool
    /// Re-sent on the next Sync (Push on Next Sync, "Keep Mine").
    public var forcePush: Bool
    public var verifyState: VerifyState
    public var syncStatus: ConfigSyncStatus
    public var linkID: ItemLinkID?
    /// Live members of ``linkID`` across repositories, folders and destinations; 0 when not
    /// linked.
    public var linkCount: Int
    /// The share file this row is held under (v0.9.0, `share_hold`): Sync leaves it out until its
    /// From Files review includes the file. Nil when the row is not held.
    public var heldBy: SharePackageID?
    /// Set when the value came from a file (1.0 F1): its name, lines and encoding, never content.
    public var file: FileSecretModel?
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
        syncStatus: ConfigSyncStatus,
        linkID: ItemLinkID? = nil,
        linkCount: Int = 0,
        heldBy: SharePackageID? = nil,
        file: FileSecretModel? = nil,
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
        self.syncStatus = syncStatus
        self.linkID = linkID
        self.linkCount = linkCount
        self.heldBy = heldBy
        self.file = file
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

/// The Azure subscription a Key Vault was found in (1.0 D6c6): its id, for matching, and the
/// name the sidebar shows ("Example Production").
public struct KeyVaultSubscriptionModel: Sendable, Hashable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}
