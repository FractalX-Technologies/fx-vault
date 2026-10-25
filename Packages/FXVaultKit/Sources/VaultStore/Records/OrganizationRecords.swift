import Foundation
import GRDB
import VaultCore

/// One `organizations` row (§6 `v17_organizations`, 1.0).
public struct OrganizationRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "organizations"

    public var id: OrganizationID
    public var login: String
    /// ``OwnerLoginValidator/foldKey(_:)`` of ``login``; unique.
    public var loginKey: String
    public var accountLogin: String
    public var lastRefreshedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: OrganizationID = OrganizationID(),
        login: String,
        accountLogin: String,
        lastRefreshedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.login = login
        loginKey = OwnerLoginValidator.foldKey(login)
        self.accountLogin = accountLogin
        self.lastRefreshedAt = lastRefreshedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The domain model with its live item counts.
    public func model(secretCount: Int = 0, variableCount: Int = 0) -> OrganizationModel {
        OrganizationModel(
            id: id,
            login: login,
            accountLogin: accountLogin,
            secretCount: secretCount,
            variableCount: variableCount,
            lastRefreshedAt: lastRefreshedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case login
        case loginKey = "login_key"
        case accountLogin = "account_login"
        case lastRefreshedAt = "last_refreshed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}

/// One `org_items` row (§6 `v17_organizations`, `v19_org_item_changes`, 1.0), ciphertext included. A value is sealed
/// with `OrgFieldAAD` (row, organization, kind, name) and fingerprinted for its row.
public struct OrgItemRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "org_items"

    public var id: ConfigItemID
    public var organizationID: OrganizationID
    public var kind: ConfigKind
    /// Uppercase (`CHECK (name = upper(name))`).
    public var name: String
    /// `value_ct`; nil for a secret with no value in the vault.
    public var valueCiphertext: Data?
    /// `value_fp`, set exactly when ``valueCiphertext`` is.
    public var valueFingerprint: Data?
    public var visibility: OrgVisibility
    /// `selected_count`: the repositories a `.selected` item reaches.
    public var selectedCount: Int?
    /// `synced_fp`: the fingerprint of the value last read from GitHub (variables).
    public var syncedFingerprint: Data?
    public var remoteUpdatedAt: Date?
    /// `is_deleted`: a deletion waiting for Sync.
    public var isDeleted: Bool
    /// `synced_visibility`: the visibility GitHub has; nil until the item was synced (an add).
    public var syncedVisibility: OrgVisibility?
    /// `repositories_edited`: the `org_item_repositories` rows are the list to send.
    public var repositoriesEdited: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ConfigItemID = ConfigItemID(),
        organizationID: OrganizationID,
        kind: ConfigKind,
        name: String,
        valueCiphertext: Data? = nil,
        valueFingerprint: Data? = nil,
        visibility: OrgVisibility,
        selectedCount: Int? = nil,
        syncedFingerprint: Data? = nil,
        remoteUpdatedAt: Date? = nil,
        isDeleted: Bool = false,
        syncedVisibility: OrgVisibility? = nil,
        repositoriesEdited: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.organizationID = organizationID
        self.kind = kind
        self.name = name
        self.valueCiphertext = valueCiphertext
        self.valueFingerprint = valueFingerprint
        self.visibility = visibility
        self.selectedCount = selectedCount
        self.syncedFingerprint = syncedFingerprint
        self.remoteUpdatedAt = remoteUpdatedAt
        self.isDeleted = isDeleted
        self.syncedVisibility = syncedVisibility
        self.repositoriesEdited = repositoriesEdited
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Pending when deleted, never synced, or its value, visibility or repository list changed.
    /// A secret without a value (GitHub never returns one) is synced.
    public var syncStatus: ConfigSyncStatus {
        if isDeleted { return .deleted }
        guard syncedVisibility != nil else { return .added }
        let valueChanged = valueFingerprint != nil && valueFingerprint != syncedFingerprint
        return valueChanged || isAccessChanged ? .modified : .synced
    }

    /// The visibility or repository list differs from the synced one (what Revert undoes).
    public var isAccessChanged: Bool {
        guard let syncedVisibility else { return false }
        return visibility != syncedVisibility || repositoriesEdited
    }

    /// The domain model (no ciphertext).
    public var model: OrgItemModel {
        OrgItemModel(
            id: id,
            organizationID: organizationID,
            kind: kind,
            name: name,
            hasValue: valueCiphertext != nil,
            visibility: visibility,
            selectedRepositoryCount: visibility == .selected ? selectedCount : nil,
            remoteUpdatedAt: remoteUpdatedAt,
            syncStatus: syncStatus,
            isAccessChanged: isAccessChanged
        )
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case organizationID = "organization_id"
        case kind
        case name
        case valueCiphertext = "value_ct"
        case valueFingerprint = "value_fp"
        case visibility
        case selectedCount = "selected_count"
        case syncedFingerprint = "synced_fp"
        case remoteUpdatedAt = "remote_updated_at"
        case isDeleted = "is_deleted"
        case syncedVisibility = "synced_visibility"
        case repositoriesEdited = "repositories_edited"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}
