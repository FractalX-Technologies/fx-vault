import Foundation
import GitHubKit
import SyncEngine
import VaultCore

/// One difference Refresh found between an organization on GitHub and the vault (1.0,
/// tasks/todo.md B7b). Names, kinds and dates only: values never leave the vault.
public struct OrgDriftModel: Sendable, Hashable, Identifiable {
    public let organizationID: OrganizationID
    /// `.secretModified` or `.variableModified` (its date, visibility or repository count
    /// differs), `.remoteAdded` or `.remoteDeleted`.
    public let kind: DriftKind
    public let itemKind: ConfigKind
    public let name: String
    /// The vault's row; nil for an item only GitHub has.
    public let itemID: ConfigItemID?
    /// GitHub's `updatedAt` (adds and changes).
    public let remoteUpdatedAt: Date?
    /// The vault has its own pending change of the item too.
    public let isConflict: Bool
    /// Keep Local sends the vault's item, which needs its value (a deletion needs none).
    public let canKeepLocal: Bool
    /// The vault's row holds a value (Accept GitHub of an add on both sides replaces it).
    public let hasLocalValue: Bool
    /// GitHub's `updatedAt` differs from the vault's (always for a row GitHub added): a secret's
    /// value may have changed, so Accept GitHub leaves it without one.
    public let isRemoteDateChanged: Bool

    public init(
        organizationID: OrganizationID,
        kind: DriftKind,
        itemKind: ConfigKind,
        name: String,
        itemID: ConfigItemID?,
        remoteUpdatedAt: Date?,
        isConflict: Bool,
        canKeepLocal: Bool,
        hasLocalValue: Bool,
        isRemoteDateChanged: Bool
    ) {
        self.organizationID = organizationID
        self.kind = kind
        self.itemKind = itemKind
        self.name = name
        self.itemID = itemID
        self.remoteUpdatedAt = remoteUpdatedAt
        self.isConflict = isConflict
        self.canKeepLocal = canKeepLocal
        self.hasLocalValue = hasLocalValue
        self.isRemoteDateChanged = isRemoteDateChanged
    }

    public var id: String {
        "\(kind.rawValue)|\(OrgItemKey.make(itemKind, name))"
    }
}

/// What one Refresh of an organization found.
public struct OrgRefreshModel: Sendable, Hashable {
    public let organizationID: OrganizationID
    /// By name, then kind.
    public let findings: [OrgDriftModel]
    /// Listed names the vault cannot hold (D29): not compared.
    public let skippedNames: [SkippedRemoteNameModel]
    public let listedAt: Date

    public init(organizationID: OrganizationID, findings: [OrgDriftModel], skippedNames: [SkippedRemoteNameModel], listedAt: Date) {
        self.organizationID = organizationID
        self.findings = findings
        self.skippedNames = skippedNames
        self.listedAt = listedAt
    }

    /// The vault's rows that changed on GitHub (the table marks them).
    public var changedItemIDs: Set<ConfigItemID> {
        Set(findings.compactMap(\.itemID))
    }
}

/// How an organization item is matched across GitHub's listing and the vault: its kind and
/// case-folded name (GitHub names are case-insensitive).
enum OrgItemKey {
    static func make(_ kind: ConfigKind, _ name: String) -> String {
        "\(kind.rawValue)|\(GitHubNameValidator.foldKey(name))"
    }
}
