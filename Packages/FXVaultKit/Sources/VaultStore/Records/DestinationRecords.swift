import Foundation
import GRDB
import VaultCore

/// One `destinations` row (§6 `v13_destinations`, v0.8.0).
///
/// The provider's identifiers live in `settings_json` (``DestinationSettings``) and its identity
/// in `target_key`, unique per repository.
public struct DestinationRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "destinations"

    public var id: DestinationID
    public var repositoryID: RepoID
    public var provider: DestinationProvider
    /// ``DestinationTargetModel/targetKey``.
    public var targetKey: String
    /// ``DestinationSettings`` as JSON.
    public var settingsJSON: String
    public var stage: String?
    /// ``EnvironmentNameValidator/foldKey(_:)`` of ``stage``.
    public var stageKey: String?
    public var sortOrder: Int
    public var lastRefreshedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: DestinationID = DestinationID(),
        repositoryID: RepoID,
        target: DestinationTargetModel,
        stage: String?,
        sortOrder: Int,
        lastRefreshedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.repositoryID = repositoryID
        provider = target.provider
        targetKey = target.targetKey
        settingsJSON = DestinationSettings(target).json
        self.stage = stage
        stageKey = stage.map(EnvironmentNameValidator.foldKey)
        self.sortOrder = sortOrder
        self.lastRefreshedAt = lastRefreshedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The target the settings describe. Throws ``StoreError/invalidStoredValue`` for a tampered
    /// or unknown row.
    public func target() throws(StoreError) -> DestinationTargetModel {
        guard let settings = DestinationSettings(json: settingsJSON), let target = settings.target(for: provider) else {
            throw .invalidStoredValue
        }
        return target
    }

    /// Replaces the stage (and its key).
    public mutating func setStage(_ stage: String?) {
        self.stage = stage
        stageKey = stage.map(EnvironmentNameValidator.foldKey)
    }

    /// The domain model, with live counts.
    public func model(
        secretCount: Int = 0,
        variableCount: Int = 0,
        pendingCount: Int = 0,
        valueMissingCount: Int = 0
    ) throws(StoreError) -> DestinationModel {
        DestinationModel(
            id: id,
            repositoryID: repositoryID,
            target: try target(),
            stage: stage,
            sortOrder: sortOrder,
            lastRefreshedAt: lastRefreshedAt,
            secretCount: secretCount,
            variableCount: variableCount,
            pendingCount: pendingCount,
            valueMissingCount: valueMissingCount,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case repositoryID = "repository_id"
        case provider
        case targetKey = "target_key"
        case settingsJSON = "settings_json"
        case stage
        case stageKey = "stage_key"
        case sortOrder = "sort_order"
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

/// `destinations.settings_json`: a flat, versioned object with the provider's identifiers.
public struct DestinationSettings: Codable, Sendable, Hashable {
    /// The settings format. Only 1 exists.
    public static let currentVersion = 1

    public var version: Int
    public var vaultName: String?
    public var tenantID: String?

    public init(_ target: DestinationTargetModel) {
        version = Self.currentVersion
        switch target {
        case .azureKeyVault(let vaultName, let tenantID):
            self.vaultName = vaultName
            self.tenantID = tenantID
        }
    }

    public init?(json: String) {
        guard let data = json.data(using: .utf8),
              let settings = try? JSONDecoder().decode(Self.self, from: data),
              settings.version == Self.currentVersion else {
            return nil
        }
        self = settings
    }

    /// Sorted keys, so equal settings always store the same text.
    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// The target for `provider`, or nil when a required identifier is missing.
    public func target(for provider: DestinationProvider) -> DestinationTargetModel? {
        switch provider {
        case .azureKeyVault:
            guard let vaultName else { return nil }
            return .azureKeyVault(vaultName: vaultName, tenantID: tenantID)
        }
    }
}

/// One `destination_items` row (§6 `v13_destinations`, v0.8.0), ciphertext included.
///
/// The value is sealed with `DestinationFieldAAD` (row, destination, kind, name) and
/// fingerprinted for its row. Sync state follows `config_items`: `synced_name` and `synced_kind`
/// are what the remote has, `synced_fp` the fingerprint of the value last confirmed there (nil
/// when the remote holds a value FX Vault never saw), `remote_version` the provider's change
/// marker (a Key Vault version).
public struct DestinationItemRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "destination_items"

    public var id: ConfigItemID
    public var destinationID: DestinationID
    public var kind: ConfigKind
    public var name: String
    public var valueCiphertext: Data?
    public var valueFingerprint: Data?
    public var isDeleted: Bool
    public var syncedName: String?
    public var syncedKind: ConfigKind?
    public var syncedFingerprint: Data?
    public var remoteVersion: String?
    public var forcePush: Bool
    public var verifyState: VerifyState
    /// ``remoteVersion`` listed right before FX Vault's last write (verification baseline).
    public var preWriteVersion: String?
    public var linkID: ItemLinkID?
    /// `share_hold` (v0.9.0): the share file this row came from while Sync's From Files review
    /// has not released it; a held row is never written to the destination. Nil when not held.
    public var shareHold: SharePackageID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ConfigItemID = ConfigItemID(),
        destinationID: DestinationID,
        kind: ConfigKind,
        name: String,
        valueCiphertext: Data?,
        valueFingerprint: Data?,
        isDeleted: Bool = false,
        syncedName: String? = nil,
        syncedKind: ConfigKind? = nil,
        syncedFingerprint: Data? = nil,
        remoteVersion: String? = nil,
        forcePush: Bool = false,
        verifyState: VerifyState = .verified,
        preWriteVersion: String? = nil,
        linkID: ItemLinkID? = nil,
        shareHold: SharePackageID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.destinationID = destinationID
        self.kind = kind
        self.name = name
        self.valueCiphertext = valueCiphertext
        self.valueFingerprint = valueFingerprint
        self.isDeleted = isDeleted
        self.syncedName = syncedName
        self.syncedKind = syncedKind
        self.syncedFingerprint = syncedFingerprint
        self.remoteVersion = remoteVersion
        self.forcePush = forcePush
        self.verifyState = verifyState
        self.preWriteVersion = preWriteVersion
        self.linkID = linkID
        self.shareHold = shareHold
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The sync facts of this row, without ciphertext.
    public var state: DestinationItemState {
        DestinationItemState(
            id: id,
            destinationID: destinationID,
            kind: kind,
            name: name,
            hasValue: valueCiphertext != nil,
            valueFingerprint: valueFingerprint,
            isDeleted: isDeleted,
            syncedName: syncedName,
            syncedKind: syncedKind,
            syncedFingerprint: syncedFingerprint,
            forcePush: forcePush,
            shareHold: shareHold
        )
    }

    public var isSynced: Bool {
        syncedName != nil
    }

    public var pendingOperation: DestinationPendingOperation? {
        state.pendingOperation
    }

    public var syncStatus: ConfigSyncStatus {
        state.syncStatus
    }

    /// The domain model (no ciphertext), with the link group's live count.
    public func model(linkCount: Int = 0) -> DestinationItemModel {
        DestinationItemModel(
            id: id,
            destinationID: destinationID,
            kind: kind,
            name: name,
            valueState: valueCiphertext == nil ? .missing : .present,
            syncedName: syncedName,
            isDeleted: isDeleted,
            forcePush: forcePush,
            verifyState: verifyState,
            syncStatus: syncStatus,
            linkID: linkID,
            linkCount: linkCount,
            heldBy: shareHold,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case destinationID = "destination_id"
        case kind
        case name
        case valueCiphertext = "value_ct"
        case valueFingerprint = "value_fp"
        case isDeleted = "is_deleted"
        case syncedName = "synced_name"
        case syncedKind = "synced_kind"
        case syncedFingerprint = "synced_fp"
        case remoteVersion = "remote_version"
        case forcePush = "force_push"
        case verifyState = "verify_state"
        case preWriteVersion = "pre_write_version"
        case linkID = "link_id"
        case shareHold = "share_hold"
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

/// The sync facts of one `destination_items` row, loaded without its ciphertext (lists, counts
/// and the Sync review read this).
public struct DestinationItemState: Sendable, Hashable, FetchableRecord {
    public var id: ConfigItemID
    public var destinationID: DestinationID
    public var kind: ConfigKind
    public var name: String
    public var hasValue: Bool
    public var valueFingerprint: Data?
    public var isDeleted: Bool
    public var syncedName: String?
    public var syncedKind: ConfigKind?
    public var syncedFingerprint: Data?
    public var forcePush: Bool
    /// `share_hold` (v0.9.0).
    public var shareHold: SharePackageID?

    public init(
        id: ConfigItemID,
        destinationID: DestinationID,
        kind: ConfigKind,
        name: String,
        hasValue: Bool,
        valueFingerprint: Data?,
        isDeleted: Bool,
        syncedName: String?,
        syncedKind: ConfigKind?,
        syncedFingerprint: Data?,
        forcePush: Bool,
        shareHold: SharePackageID? = nil
    ) {
        self.id = id
        self.destinationID = destinationID
        self.kind = kind
        self.name = name
        self.hasValue = hasValue
        self.valueFingerprint = valueFingerprint
        self.isDeleted = isDeleted
        self.syncedName = syncedName
        self.syncedKind = syncedKind
        self.syncedFingerprint = syncedFingerprint
        self.forcePush = forcePush
        self.shareHold = shareHold
    }

    /// The columns ``init(row:)`` reads, in order.
    static let selection = """
        id, destination_id, kind, name, value_ct IS NOT NULL AS has_value, value_fp, is_deleted,
        synced_name, synced_kind, synced_fp, force_push, share_hold
        """

    public init(row: Row) throws {
        guard let id = ConfigItemID(uuidString: row["id"] ?? ""),
              let destinationID = DestinationID(uuidString: row["destination_id"] ?? ""),
              let kind = ConfigKind(rawValue: row["kind"] ?? ""),
              let name: String = row["name"] else {
            throw StoreError.invalidStoredValue
        }
        let syncedKindText: String? = row["synced_kind"]
        let shareHoldText: String? = row["share_hold"]
        let shareHold = try shareHoldText.map { text in
            guard let id = SharePackageID(uuidString: text) else { throw StoreError.invalidStoredValue }
            return id
        }
        self.init(
            id: id,
            destinationID: destinationID,
            kind: kind,
            name: name,
            hasValue: row["has_value"] ?? false,
            valueFingerprint: row["value_fp"],
            isDeleted: row["is_deleted"] ?? false,
            syncedName: row["synced_name"],
            syncedKind: syncedKindText.flatMap(ConfigKind.init(rawValue:)),
            syncedFingerprint: row["synced_fp"],
            forcePush: row["force_push"] ?? false,
            shareHold: shareHold
        )
    }

    /// True once the remote has the item.
    public var isSynced: Bool {
        syncedName != nil
    }

    /// True when the value differs from what the remote was last confirmed to hold (or the
    /// remote's value was never seen).
    public var isValueChanged: Bool {
        guard hasValue, let valueFingerprint else { return false }
        return syncedFingerprint != valueFingerprint
    }

    /// Whether the next Sync writes this row, and how. A never-pushed row without a value is
    /// still an add (preflight blocks it as value missing); a pushed row without a local value
    /// has nothing to send.
    public var pendingOperation: DestinationPendingOperation? {
        if isDeleted {
            return isSynced ? .delete : nil
        }
        guard isSynced else { return .add }
        guard hasValue else { return nil }
        if forcePush || isValueChanged || syncedKind != kind {
            return .update
        }
        return nil
    }

    /// The status the table shows (``ConfigSyncStatus/derive(_:)``'s rules).
    public var syncStatus: ConfigSyncStatus {
        ConfigSyncStatus.derive(ConfigSyncStatus.Facts(
            kind: kind,
            isDeleted: isDeleted,
            isSynced: isSynced,
            isRenamed: false,
            isValueChanged: isValueChanged || (hasValue && syncedKind != nil && syncedKind != kind),
            forcePush: forcePush,
            valueState: hasValue ? .present : .missing,
            provenance: .local
        ))
    }
}

/// What the next Sync does with a destination item.
public enum DestinationPendingOperation: String, Sendable, Hashable, CaseIterable {
    /// The remote does not have it yet.
    case add
    /// The remote has it; its value (or type) changes.
    case update
    /// The remote has it; it is deleted there.
    case delete
}

/// One `destination_journal` row (§6 `v13_destinations`, v0.8.0): a destination write, recorded
/// `in_flight` before it starts. Names only, never values.
public struct DestinationJournalRecord: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "destination_journal"

    public enum Operation: String, Codable, Sendable, Hashable, CaseIterable {
        case set
        case delete
        case recover
    }

    public enum State: String, Codable, Sendable, Hashable, CaseIterable {
        case inFlight = "in_flight"
        case succeeded
        case failed
        case indeterminate
        case reconciled
    }

    public var id: Int64?
    public var runID: SyncRunID
    public var destinationID: DestinationID?
    public var itemID: ConfigItemID?
    public var operation: Operation
    public var itemName: String
    public var state: State
    public var errorCode: String?
    public var preWriteVersion: String?
    public var pushedFingerprint: Data?
    public var startedAt: Date
    public var finishedAt: Date?

    public init(
        id: Int64? = nil,
        runID: SyncRunID,
        destinationID: DestinationID?,
        itemID: ConfigItemID?,
        operation: Operation,
        itemName: String,
        state: State = .inFlight,
        errorCode: String? = nil,
        preWriteVersion: String? = nil,
        pushedFingerprint: Data? = nil,
        startedAt: Date,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.destinationID = destinationID
        self.itemID = itemID
        self.operation = operation
        self.itemName = itemName
        self.state = state
        self.errorCode = errorCode
        self.preWriteVersion = preWriteVersion
        self.pushedFingerprint = pushedFingerprint
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case runID = "run_id"
        case destinationID = "destination_id"
        case itemID = "item_id"
        case operation = "op"
        case itemName = "item_name"
        case state
        case errorCode = "error_code"
        case preWriteVersion = "pre_write_version"
        case pushedFingerprint = "pushed_fp"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}
