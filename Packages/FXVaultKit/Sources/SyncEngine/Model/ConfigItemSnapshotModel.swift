import Foundation
import VaultCore

/// The facts of one `config_items` row that change derivation and drift detection need
/// (tasks/todo.md §6, §7.1, §7.7). Carries fingerprints, never a value or a ciphertext.
///
/// SyncEngine does not depend on VaultStore: VaultData maps each `ConfigItemState` to this model
/// field by field (`valueFingerprint`, `syncedFingerprint`, `hasSyncedValue`, ...).
public struct ConfigItemSnapshotModel: Sendable, Hashable, Identifiable {
    public var id: ConfigItemID
    /// Repository level or one environment. Immutable once synced (D11).
    public var scope: ConfigScope
    /// Immutable once synced (D11).
    public var kind: ConfigKind
    /// The desired name (uppercase).
    public var name: String
    /// `value_fp`: the row-bound fingerprint of the local value; nil when the value is missing
    /// (`value_ct IS NULL`, a secret only).
    public var valueFingerprint: Data?
    /// `is_deleted`: tombstone pending deletion on GitHub.
    public var isDeleted: Bool
    /// `synced_name`: the name GitHub has; nil when never pushed (pending add).
    public var syncedName: String?
    /// `synced_value_ct IS NOT NULL` (Revert can restore a value).
    public var hasSyncedValue: Bool
    /// `synced_fp`.
    public var syncedFingerprint: Data?
    /// `force_push`.
    public var forcePush: Bool
    /// `force_push_requested_at`: when the user asked for the push (Fill without "Already
    /// matches GitHub", or Push on Next Sync). Nil for pushes FX Vault scheduled itself (drift
    /// "Keep local", an expired verification). Only meaningful while ``forcePush`` is set.
    public var forcePushRequestedAt: Date?
    /// `remote_updated_at`: GitHub's `updatedAt` recorded at the last verification.
    public var remoteUpdatedAt: Date?
    /// `verify_state`.
    public var verifyState: VerifyState
    /// `pre_write_updated_at`: the verification baseline (§7.3).
    public var preWriteUpdatedAt: Date?
    public var provenance: ConfigProvenance

    public init(
        id: ConfigItemID = ConfigItemID(),
        scope: ConfigScope,
        kind: ConfigKind,
        name: String,
        valueFingerprint: Data?,
        isDeleted: Bool = false,
        syncedName: String? = nil,
        hasSyncedValue: Bool = false,
        syncedFingerprint: Data? = nil,
        forcePush: Bool = false,
        forcePushRequestedAt: Date? = nil,
        remoteUpdatedAt: Date? = nil,
        verifyState: VerifyState = .verified,
        preWriteUpdatedAt: Date? = nil,
        provenance: ConfigProvenance = .local
    ) {
        self.id = id
        self.scope = scope
        self.kind = kind
        self.name = name
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
    }

    /// A local value exists (`value_ct IS NOT NULL`).
    public var hasValue: Bool {
        valueFingerprint != nil
    }

    /// GitHub has the item under ``syncedName``.
    public var isSynced: Bool {
        syncedName != nil
    }

    /// Fold key of ``name``.
    public var nameKey: String {
        GitHubNameValidator.foldKey(name)
    }

    /// Fold key of ``syncedName``.
    public var syncedNameKey: String? {
        syncedName.map(GitHubNameValidator.foldKey)
    }

    /// A synced row whose name changed (`name != synced_name`, §7.1).
    public var isRenamed: Bool {
        guard let syncedNameKey else { return false }
        return syncedNameKey != nameKey
    }

    /// The local value differs from the synced one, or nothing was synced yet (§7.1 row 7).
    public var isValueChanged: Bool {
        guard let valueFingerprint else { return false }
        guard let syncedFingerprint else { return true }
        return valueFingerprint != syncedFingerprint
    }

    /// D27 for a synced secret listed on GitHub with `updatedAt`: true when GitHub changed it
    /// since the vault last saw it (`remote_updated_at`). A push the user requested
    /// (``forcePushRequestedAt``) covers the changes GitHub made clearly before the request;
    /// a change after it, or one whose order is unclear (whole-second `updatedAt`, clock skew:
    /// ``SyncEngineConstants/requestedPushClockMargin``), counts. Shared by
    /// ``RemoteBaseChecker`` and ``DriftDetector``.
    func isSecretChangedOnGitHub(updatedAt: Date?) -> Bool {
        guard !DriftDetector.isSameTimestamp(updatedAt, remoteUpdatedAt) else { return false }
        guard forcePush, let requestedAt = forcePushRequestedAt, let updatedAt else { return true }
        let requestSecond = requestedAt.timeIntervalSince1970.rounded(.down)
        let coveredBefore = requestSecond - SyncEngineConstants.requestedPushClockMargin
        return updatedAt.timeIntervalSince1970 >= coveredBefore
    }

    /// The row has something to push or delete (ignoring whether it can be pushed).
    public var hasPendingChange: Bool {
        if isDeleted { return isSynced }
        return !isSynced || isRenamed || isValueChanged || forcePush
    }

    /// The facts behind the status column, consistent with the change table.
    public var syncFacts: ConfigSyncStatus.Facts {
        ConfigSyncStatus.Facts(
            kind: kind,
            isDeleted: isDeleted,
            isSynced: isSynced,
            isRenamed: isRenamed,
            isValueChanged: isValueChanged,
            forcePush: forcePush,
            valueState: hasValue ? .present : .missing,
            provenance: provenance
        )
    }
}
