import Foundation

/// A secret or variable as the UI and repositories see it (`config_items` row, §6).
///
/// Never carries a value, a ciphertext or a fingerprint: only whether a local value exists
/// (``valueState``). Values are decrypted on demand through VaultData.
public struct ConfigItemModel: Sendable, Hashable, Identifiable {
    public var id: ConfigItemID
    public var repositoryID: RepoID
    /// Repository level or one environment. Immutable once synced (D11).
    public var scope: ConfigScope
    /// Secret or variable. Immutable once synced (D11).
    public var kind: ConfigKind
    /// The desired name, uppercase (``GitHubNameValidator``).
    public var name: String
    /// Whether a local value exists. Secrets imported from GitHub are ``ConfigValueState/missing``.
    public var valueState: ConfigValueState
    /// The name GitHub has, or nil if never pushed (pending add).
    public var syncedName: String?
    /// Tombstone: pending deletion on GitHub.
    public var isDeleted: Bool
    /// Set by Push on Next Sync, a fill that pushes, "Keep local" drift resolution or a failed
    /// verification; cleared by a push and by Revert.
    public var forcePush: Bool
    /// GitHub's `updatedAt` recorded at the last verification.
    public var remoteUpdatedAt: Date?
    public var verifyState: VerifyState
    public var provenance: ConfigProvenance
    /// Present when ``provenance`` is ``ConfigProvenance/share``.
    public var shareOrigin: ShareOriginModel?
    /// Derived by the repository layer (fingerprints never leave it); see
    /// ``ConfigSyncStatus/derive(_:)``.
    public var syncStatus: ConfigSyncStatus
    /// The group of linked copies this item belongs to (v0.4.1), or nil.
    public var linkID: ItemLinkID?
    /// How many live items (this one included) share ``linkID``, set by the item observation;
    /// 0 when the item is not linked or the count was not loaded. The table shows the link from 2.
    public var linkCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ConfigItemID = ConfigItemID(),
        repositoryID: RepoID,
        scope: ConfigScope,
        kind: ConfigKind,
        name: String,
        valueState: ConfigValueState,
        syncedName: String? = nil,
        isDeleted: Bool = false,
        forcePush: Bool = false,
        remoteUpdatedAt: Date? = nil,
        verifyState: VerifyState = .verified,
        provenance: ConfigProvenance = .local,
        shareOrigin: ShareOriginModel? = nil,
        syncStatus: ConfigSyncStatus,
        linkID: ItemLinkID? = nil,
        linkCount: Int = 0,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.scope = scope
        self.kind = kind
        self.name = name
        self.valueState = valueState
        self.syncedName = syncedName
        self.isDeleted = isDeleted
        self.forcePush = forcePush
        self.remoteUpdatedAt = remoteUpdatedAt
        self.verifyState = verifyState
        self.provenance = provenance
        self.shareOrigin = shareOrigin
        self.syncStatus = syncStatus
        self.linkID = linkID
        self.linkCount = linkCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True when at least one other live item shares this item's link (v0.4.1).
    public var isLinked: Bool {
        linkID != nil && linkCount > 1
    }

    /// True once GitHub has the item under ``syncedName``.
    public var isSynced: Bool {
        syncedName != nil
    }

    /// True when a local value exists.
    public var hasValue: Bool {
        valueState == .present
    }

    /// Kind and scope can no longer change (D11): "Convert/Move" creates a new row instead.
    public var isKindAndScopeLocked: Bool {
        isSynced
    }

    /// `name` case-folded; GitHub item names are case-insensitive.
    public var nameKey: String {
        GitHubNameValidator.foldKey(name)
    }
}

/// Whether a local value exists (`config_items.value_ct IS NOT NULL`).
public enum ConfigValueState: String, Sendable, Hashable, Codable, CaseIterable {
    case present
    case missing
}

/// `config_items.verify_state` (§7.3 verification).
public enum VerifyState: String, Sendable, Hashable, Codable, CaseIterable {
    case verified
    case pending
}

/// `config_items.provenance` (§6 `v6_sharing`).
public enum ConfigProvenance: String, Sendable, Hashable, Codable, CaseIterable {
    /// Entered or imported locally (.env, editor).
    case local
    /// Imported from GitHub (repository import, drift "Accept GitHub").
    case github
    /// Filled or added from a share package; shown as "from share, unverified" until a verified
    /// push or a drift-confirmed match.
    case share
}

/// Where a shared value came from (`config_items.provenance_detail`, §9.5).
public struct ShareOriginModel: Sendable, Hashable, Codable {
    public var packageID: SharePackageID
    /// The sender's display name as the package states it. Unverified.
    public var senderName: String?

    public init(packageID: SharePackageID, senderName: String?) {
        self.packageID = packageID
        self.senderName = senderName
    }
}

/// The Status column of the config table (§10).
public enum ConfigSyncStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case synced
    case added
    case modified
    case deleted
    /// A change that cannot be pushed (for example a secret whose value is missing locally).
    case blocked
    /// Synced, but the local value came from a share and has not been confirmed on GitHub.
    case unverifiedShare
    /// Synced and unchanged, but the next Sync re-sends the local value (`force_push`: Push on
    /// Next Sync, drift "Keep local", an expired verification). Pending like ``modified``.
    case willPush

    /// Local facts the status is derived from. Fingerprints stay in the repository layer; it
    /// passes only whether they differ.
    public struct Facts: Sendable, Hashable {
        public var kind: ConfigKind
        public var isDeleted: Bool
        public var isSynced: Bool
        /// `name != synced_name`.
        public var isRenamed: Bool
        /// `synced_fp == nil` or `value_fp != synced_fp` (only meaningful with a local value).
        public var isValueChanged: Bool
        public var forcePush: Bool
        public var valueState: ConfigValueState
        public var provenance: ConfigProvenance

        public init(
            kind: ConfigKind,
            isDeleted: Bool,
            isSynced: Bool,
            isRenamed: Bool,
            isValueChanged: Bool,
            forcePush: Bool,
            valueState: ConfigValueState,
            provenance: ConfigProvenance
        ) {
            self.kind = kind
            self.isDeleted = isDeleted
            self.isSynced = isSynced
            self.isRenamed = isRenamed
            self.isValueChanged = isValueChanged
            self.forcePush = forcePush
            self.valueState = valueState
            self.provenance = provenance
        }
    }

    /// Derives the status from local facts, following the §7.1 change table.
    ///
    /// Priority: deleted, then blocked (a change that needs the missing value), then added,
    /// then modified (a changed value; ``willPush`` when only `force_push` is set), then
    /// unverified share, then synced. A missing secret value with no pending
    /// change is ``synced`` (the value is on GitHub; the UI shows the "Value missing" chip).
    /// A tombstone that was never synced is not a valid stored state (the row is removed
    /// instead, §7.1 coalescing) and derives as ``synced`` (nothing to push).
    public static func derive(_ facts: Facts) -> ConfigSyncStatus {
        if facts.isDeleted {
            return facts.isSynced ? .deleted : .synced
        }
        let hasValue = facts.valueState == .present
        let isAdd = !facts.isSynced || facts.isRenamed
        let isModify = facts.isSynced && hasValue && (facts.isValueChanged || facts.forcePush)
        let needsValue = isAdd || facts.forcePush
        if !hasValue, needsValue {
            return .blocked
        }
        if isAdd {
            return .added
        }
        if isModify {
            return facts.isValueChanged ? .modified : .willPush
        }
        if facts.provenance == .share {
            return .unverifiedShare
        }
        return .synced
    }
}
