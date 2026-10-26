import Foundation
import GRDB
import VaultCore

/// One `config_items` row (§6 `v3_config` + `v6_sharing` + `v8_force_push_requested_at` +
/// `v9_item_links` + `v14_project_shares`), ciphertexts included.
///
/// The `*Ciphertext` and `*Fingerprint` blobs are opaque here: VaultCrypto produces them and
/// VaultData decrypts them. Fetch this record only to read or write a value; lists, status and
/// pending-change inputs use ``ConfigItemState``, which never loads ciphertext.
public struct ConfigItemRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "config_items"

    public var id: ConfigItemID
    public var repositoryID: RepoID
    /// Nil at repository level. Immutable once synced (D11).
    public var environmentID: EnvironmentID?
    /// Immutable once synced (D11).
    public var kind: ConfigKind
    /// Uppercase (`CHECK (name = upper(name))`).
    public var name: String
    /// `value_ct`: nil means the secret value is missing locally. Must be nil exactly when
    /// ``valueFingerprint`` is nil.
    public var valueCiphertext: Data?
    /// `value_fp`: the row-bound HMAC fingerprint of the value (§5.4).
    public var valueFingerprint: Data?
    public var isDeleted: Bool
    /// The name GitHub has; nil means never pushed (pending add).
    public var syncedName: String?
    /// `synced_value_ct`: the last pushed value, for Revert.
    public var syncedValueCiphertext: Data?
    /// `synced_fp`: the fingerprint of the last pushed value.
    public var syncedFingerprint: Data?
    public var forcePush: Bool
    /// `force_push_requested_at`: when the user asked for this push (nil for a push FX Vault
    /// scheduled itself). Cleared with ``forcePush``.
    public var forcePushRequestedAt: Date?
    public var remoteUpdatedAt: Date?
    public var verifyState: VerifyState
    /// Verification baseline: GitHub's `updatedAt` listed right before the write (§7.3).
    public var preWriteUpdatedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var provenance: ConfigProvenance
    /// `provenance_detail`: package id and unverified sender name, as JSON.
    public var shareOrigin: ShareOriginModel?
    /// `link_id`: the group of linked copies this row belongs to (v0.4.1), or nil.
    public var linkID: ItemLinkID?
    /// `share_hold`: the share file this row came from while Sync's From Files review has not
    /// released it (v0.9.0); a held row never enters a sync plan. Nil when not held.
    public var shareHold: SharePackageID?
    /// `file_detail` (v21): the file the value came from, as JSON; nil for a typed value.
    public var file: FileSecretModel?

    public init(
        id: ConfigItemID = ConfigItemID(),
        repositoryID: RepoID,
        scope: ConfigScope,
        kind: ConfigKind,
        name: String,
        valueCiphertext: Data?,
        valueFingerprint: Data?,
        isDeleted: Bool = false,
        syncedName: String? = nil,
        syncedValueCiphertext: Data? = nil,
        syncedFingerprint: Data? = nil,
        forcePush: Bool = false,
        forcePushRequestedAt: Date? = nil,
        remoteUpdatedAt: Date? = nil,
        verifyState: VerifyState = .verified,
        preWriteUpdatedAt: Date? = nil,
        provenance: ConfigProvenance = .local,
        shareOrigin: ShareOriginModel? = nil,
        linkID: ItemLinkID? = nil,
        shareHold: SharePackageID? = nil,
        file: FileSecretModel? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.repositoryID = repositoryID
        environmentID = scope.environmentID
        self.kind = kind
        self.name = name
        self.valueCiphertext = valueCiphertext
        self.valueFingerprint = valueFingerprint
        self.isDeleted = isDeleted
        self.syncedName = syncedName
        self.syncedValueCiphertext = syncedValueCiphertext
        self.syncedFingerprint = syncedFingerprint
        self.forcePush = forcePush
        self.forcePushRequestedAt = forcePushRequestedAt
        self.remoteUpdatedAt = remoteUpdatedAt
        self.verifyState = verifyState
        self.preWriteUpdatedAt = preWriteUpdatedAt
        self.provenance = provenance
        self.shareOrigin = shareOrigin
        self.linkID = linkID
        self.shareHold = shareHold
        self.file = file
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Repository level or the environment.
    public var scope: ConfigScope {
        get { ConfigScope(environmentID: environmentID) }
        set { environmentID = newValue.environmentID }
    }

    /// The row without its ciphertexts.
    public var state: ConfigItemState {
        ConfigItemState(
            id: id,
            repositoryID: repositoryID,
            environmentID: environmentID,
            kind: kind,
            name: name,
            hasValue: valueCiphertext != nil,
            valueFingerprint: valueFingerprint,
            isDeleted: isDeleted,
            syncedName: syncedName,
            hasSyncedValue: syncedValueCiphertext != nil,
            syncedFingerprint: syncedFingerprint,
            forcePush: forcePush,
            forcePushRequestedAt: forcePushRequestedAt,
            remoteUpdatedAt: remoteUpdatedAt,
            verifyState: verifyState,
            preWriteUpdatedAt: preWriteUpdatedAt,
            provenance: provenance,
            shareOrigin: shareOrigin,
            linkID: linkID,
            shareHold: shareHold,
            file: file,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// The domain model, with its derived ``ConfigSyncStatus``.
    public var model: ConfigItemModel {
        state.model
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case repositoryID = "repository_id"
        case environmentID = "environment_id"
        case kind
        case name
        case valueCiphertext = "value_ct"
        case valueFingerprint = "value_fp"
        case isDeleted = "is_deleted"
        case syncedName = "synced_name"
        case syncedValueCiphertext = "synced_value_ct"
        case syncedFingerprint = "synced_fp"
        case forcePush = "force_push"
        case forcePushRequestedAt = "force_push_requested_at"
        case remoteUpdatedAt = "remote_updated_at"
        case verifyState = "verify_state"
        case preWriteUpdatedAt = "pre_write_updated_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case provenance
        case shareOrigin = "provenance_detail"
        case linkID = "link_id"
        case shareHold = "share_hold"
        case file = "file_detail"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}

/// A `config_items` row without ciphertexts: what lists, status chips and the sync diff need
/// (§7.1 uses only fingerprints and flags). Read-only projection.
public struct ConfigItemState: Codable, Sendable, Hashable, Identifiable, FetchableRecord {
    public var id: ConfigItemID
    public var repositoryID: RepoID
    public var environmentID: EnvironmentID?
    public var kind: ConfigKind
    public var name: String
    /// `value_ct IS NOT NULL`.
    public var hasValue: Bool
    public var valueFingerprint: Data?
    public var isDeleted: Bool
    public var syncedName: String?
    /// `synced_value_ct IS NOT NULL` (Revert is possible).
    public var hasSyncedValue: Bool
    public var syncedFingerprint: Data?
    public var forcePush: Bool
    /// `force_push_requested_at`.
    public var forcePushRequestedAt: Date?
    public var remoteUpdatedAt: Date?
    public var verifyState: VerifyState
    public var preWriteUpdatedAt: Date?
    public var provenance: ConfigProvenance
    public var shareOrigin: ShareOriginModel?
    /// `link_id` (v0.4.1).
    public var linkID: ItemLinkID?
    /// `share_hold` (v0.9.0): held rows stay out of every sync plan.
    public var shareHold: SharePackageID?
    /// `file_detail` (v21).
    public var file: FileSecretModel?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ConfigItemID,
        repositoryID: RepoID,
        environmentID: EnvironmentID?,
        kind: ConfigKind,
        name: String,
        hasValue: Bool,
        valueFingerprint: Data?,
        isDeleted: Bool,
        syncedName: String?,
        hasSyncedValue: Bool,
        syncedFingerprint: Data?,
        forcePush: Bool,
        forcePushRequestedAt: Date? = nil,
        remoteUpdatedAt: Date?,
        verifyState: VerifyState,
        preWriteUpdatedAt: Date?,
        provenance: ConfigProvenance,
        shareOrigin: ShareOriginModel?,
        linkID: ItemLinkID? = nil,
        shareHold: SharePackageID? = nil,
        file: FileSecretModel? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.environmentID = environmentID
        self.kind = kind
        self.name = name
        self.hasValue = hasValue
        self.valueFingerprint = valueFingerprint
        self.isDeleted = isDeleted
        self.syncedName = syncedName
        self.hasSyncedValue = hasSyncedValue
        self.syncedFingerprint = syncedFingerprint
        self.forcePush = forcePush
        self.forcePushRequestedAt = forcePushRequestedAt
        self.remoteUpdatedAt = remoteUpdatedAt
        self.verifyState = verifyState
        self.preWriteUpdatedAt = preWriteUpdatedAt
        self.provenance = provenance
        self.shareOrigin = shareOrigin
        self.linkID = linkID
        self.shareHold = shareHold
        self.file = file
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var scope: ConfigScope {
        ConfigScope(environmentID: environmentID)
    }

    /// `synced_name != nil`.
    public var isSynced: Bool {
        syncedName != nil
    }

    /// The local facts behind the status column (§7.1). The value counts as changed when it
    /// exists and its fingerprint differs from the synced one (or nothing was synced yet).
    public var syncFacts: ConfigSyncStatus.Facts {
        let isValueChanged = valueFingerprint != nil
            && (syncedFingerprint == nil || valueFingerprint != syncedFingerprint)
        return ConfigSyncStatus.Facts(
            kind: kind,
            isDeleted: isDeleted,
            isSynced: isSynced,
            isRenamed: syncedName.map { $0 != name } ?? false,
            isValueChanged: isValueChanged,
            forcePush: forcePush,
            valueState: hasValue ? .present : .missing,
            provenance: provenance
        )
    }

    /// The domain model, with ``ConfigSyncStatus/derive(_:)`` applied to ``syncFacts``.
    public var model: ConfigItemModel {
        ConfigItemModel(
            id: id,
            repositoryID: repositoryID,
            scope: scope,
            kind: kind,
            name: name,
            valueState: hasValue ? .present : .missing,
            syncedName: syncedName,
            isDeleted: isDeleted,
            forcePush: forcePush,
            remoteUpdatedAt: remoteUpdatedAt,
            verifyState: verifyState,
            provenance: provenance,
            shareOrigin: shareOrigin,
            syncStatus: ConfigSyncStatus.derive(syncFacts),
            linkID: linkID,
            heldBy: shareHold,
            file: file,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case repositoryID = "repository_id"
        case environmentID = "environment_id"
        case kind
        case name
        case hasValue = "has_value"
        case valueFingerprint = "value_fp"
        case isDeleted = "is_deleted"
        case syncedName = "synced_name"
        case hasSyncedValue = "has_synced_value"
        case syncedFingerprint = "synced_fp"
        case forcePush = "force_push"
        case forcePushRequestedAt = "force_push_requested_at"
        case remoteUpdatedAt = "remote_updated_at"
        case verifyState = "verify_state"
        case preWriteUpdatedAt = "pre_write_updated_at"
        case provenance
        case shareOrigin = "provenance_detail"
        case linkID = "link_id"
        case shareHold = "share_hold"
        case file = "file_detail"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// The `SELECT` list that produces this projection from `config_items`.
    static var selection: [any SQLSelectable] {
        [
            CodingKeys.id,
            CodingKeys.repositoryID,
            CodingKeys.environmentID,
            CodingKeys.kind,
            CodingKeys.name,
            (ConfigItemRecord.CodingKeys.valueCiphertext != nil).forKey(CodingKeys.hasValue.rawValue),
            CodingKeys.valueFingerprint,
            CodingKeys.isDeleted,
            CodingKeys.syncedName,
            (ConfigItemRecord.CodingKeys.syncedValueCiphertext != nil).forKey(CodingKeys.hasSyncedValue.rawValue),
            CodingKeys.syncedFingerprint,
            CodingKeys.forcePush,
            CodingKeys.forcePushRequestedAt,
            CodingKeys.remoteUpdatedAt,
            CodingKeys.verifyState,
            CodingKeys.preWriteUpdatedAt,
            CodingKeys.provenance,
            CodingKeys.shareOrigin,
            CodingKeys.linkID,
            CodingKeys.shareHold,
            CodingKeys.file,
            CodingKeys.createdAt,
            CodingKeys.updatedAt,
        ]
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}
