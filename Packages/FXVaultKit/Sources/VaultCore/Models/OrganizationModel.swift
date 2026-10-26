import Foundation

/// A GitHub organization in the vault (1.0, tasks/todo.md B5, `organizations` row): its own
/// secrets and variables, read through one account that has `admin:org` and the admin role (B4).
public struct OrganizationModel: Sendable, Hashable, Identifiable {
    public var id: OrganizationID
    /// The login as GitHub spells it; unique by ``OwnerLoginValidator/foldKey(_:)``.
    public var login: String
    /// The gh account that reads it.
    public var accountLogin: String
    /// Live secrets and variables, set by the store's queries.
    public var secretCount: Int
    public var variableCount: Int
    public var lastRefreshedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: OrganizationID = OrganizationID(),
        login: String,
        accountLogin: String,
        secretCount: Int = 0,
        variableCount: Int = 0,
        lastRefreshedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.login = login
        self.accountLogin = accountLogin
        self.secretCount = secretCount
        self.variableCount = variableCount
        self.lastRefreshedAt = lastRefreshedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// What a repository gets from its organization (1.0, B7a): the organization's live items whose
/// visibility reaches it. A `selected` item counts only when FX Vault knows its list.
public struct InheritedOrgItemsModel: Sendable, Hashable {
    public var organizationID: OrganizationID
    public var organizationLogin: String
    /// By name, then kind.
    public var items: [OrgItemModel]

    public init(organizationID: OrganizationID, organizationLogin: String, items: [OrgItemModel]) {
        self.organizationID = organizationID
        self.organizationLogin = organizationLogin
        self.items = items
    }
}

/// One organization secret or variable (`org_items` row), without its value.
public struct OrgItemModel: Sendable, Hashable, Identifiable {
    public var id: ConfigItemID
    public var organizationID: OrganizationID
    public var kind: ConfigKind
    public var name: String
    /// False for a secret that has no value in the vault: GitHub never returns secret values.
    public var hasValue: Bool
    public var visibility: OrgVisibility
    /// How many repositories a `.selected` item reaches; nil for the other visibilities.
    public var selectedRepositoryCount: Int?
    public var remoteUpdatedAt: Date?
    /// A change waiting for Sync (1.0, B6b): added, modified, deleted or synced.
    public var syncStatus: ConfigSyncStatus
    /// Who can use it differs from GitHub (Revert Access undoes it; a changed value stays).
    public var isAccessChanged: Bool

    public init(
        id: ConfigItemID,
        organizationID: OrganizationID,
        kind: ConfigKind,
        name: String,
        hasValue: Bool,
        visibility: OrgVisibility,
        selectedRepositoryCount: Int?,
        remoteUpdatedAt: Date?,
        syncStatus: ConfigSyncStatus = .synced,
        isAccessChanged: Bool = false
    ) {
        self.id = id
        self.organizationID = organizationID
        self.kind = kind
        self.name = name
        self.hasValue = hasValue
        self.visibility = visibility
        self.selectedRepositoryCount = selectedRepositoryCount
        self.remoteUpdatedAt = remoteUpdatedAt
        self.syncStatus = syncStatus
        self.isAccessChanged = isAccessChanged
    }
}
