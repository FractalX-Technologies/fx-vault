import Foundation
import GitHubKit
import SharingKit
import VaultCore
import VaultCrypto
import VaultStore

/// Why a ``SpaceRepository`` call failed. Carries no names or values.
public enum SpaceRepositoryError: Error, Sendable, Hashable {
    /// The vault is locked (space keys and device keys live in it).
    case vault(VaultError)
    case store(StoreError)
    /// A stored or received version broke the log rules (S3, S7).
    case log(SpaceLogFailure)
    /// gh failed while reading or writing the scope's marker.
    case github(GHError)
    case spaceNotFound
    /// The repository is not on GitHub yet (a space binds to its GitHub id).
    case repositoryNotOnGitHub
    /// The scope has pending changes or secrets without a local value (``SpaceReadinessModel``).
    case scopeNotReady
    /// This scope is already shared on this Mac.
    case alreadyShared
    /// GitHub already lists a marker in this scope: someone shares it already and can add you.
    case sharedOnGitHub
    /// The scope's gate does not allow a new version now (behind, being published, forked).
    case gate(SpaceGateDecision)
    /// This device is not a member of the space (removed, or never added).
    case notAMember
    /// A teammate the request names is not paired.
    case teammateNotFound
    /// A member list that would leave no member, or remove this device.
    case invalidMembers
    /// Restoring a value went through Config, which refused it.
    case config(ConfigRepositoryError)
    case unexpected

    static func wrap(_ error: any Error) -> SpaceRepositoryError {
        switch error {
        case let error as SpaceRepositoryError: error
        case let error as VaultError: .vault(error)
        case let error as StoreError: .store(error)
        case let error as SpaceLogFailure: .log(error)
        case let error as GHError: .github(error)
        case let error as ConfigRepositoryError: .config(error)
        case is ShareError: .log(.malformed)
        case is CryptoError: .vault(.corrupted(.fieldDecryptionFailed))
        default: .unexpected
        }
    }
}

/// A shared scope on this Mac (works while locked: no keys, no names of members).
public struct SpaceSummaryModel: Sendable, Hashable, Identifiable {
    public let id: SpaceID
    public let repositoryID: RepoID
    public let scope: ConfigScope
    public let headVersion: Int64
    public let epoch: Int64
    /// This Mac claimed a version whose `published` marker is not confirmed on GitHub yet.
    public let isPublishing: Bool
    public let updatedAt: Date

    init(record: SpaceRecord) {
        id = record.id
        repositoryID = record.repositoryID
        scope = record.scope
        headVersion = record.headVersion
        epoch = record.epoch
        isPublishing = record.claimedVersion != nil
        updatedAt = record.updatedAt
    }
}

/// Whether a scope can be shared now (S1: the first version must describe what GitHub holds).
public struct SpaceReadinessModel: Sendable, Hashable {
    /// Items with a change that is not on GitHub yet (Sync first).
    public let pendingNames: [String]
    /// Secrets GitHub has whose value this Mac does not know (fill them first).
    public let missingValueNames: [String]
    /// Items in the scope (for the confirmation text).
    public let itemCount: Int

    public var isReady: Bool {
        pendingNames.isEmpty && missingValueNames.isEmpty
    }
}

/// One member of a space, as its log names it.
public struct SpaceMemberSummaryModel: Sendable, Hashable, Identifiable {
    public let deviceID: String
    public let name: String
    public let login: String
    public let macName: String
    public let isThisMac: Bool
    /// True when the member is also paired on this Mac (presence and sync reach it).
    public let isPaired: Bool

    public var id: String {
        deviceID
    }
}

/// A space with its members (log only, no keys).
public struct SpaceDetailModel: Sendable, Hashable, Identifiable {
    public let summary: SpaceSummaryModel
    public let members: [SpaceMemberSummaryModel]
    /// This device is still a member (it can publish and read new versions).
    public let isMember: Bool

    public var id: SpaceID {
        summary.id
    }
}

/// One version as History shows it (S3; decrypting needs the vault unlocked).
public struct SpaceVersionSummaryModel: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case shared
        case published
        case members
    }

    public let version: Int64
    public let kind: Kind
    public let authorName: String
    public let authorMacName: String
    public let createdAt: Date
    /// "What changed?" as the author typed it (may be empty).
    public let reason: String
    /// Items added, changed or removed since the previous content version, by name.
    public let changedItems: [SpaceChangedItemModel]

    public var id: Int64 {
        version
    }

    /// The names of ``changedItems``.
    public var changedNames: [String] {
        changedItems.map(\.name)
    }
}

/// An item a version added, changed or removed.
public struct SpaceChangedItemModel: Sendable, Hashable, Identifiable {
    public let kind: ConfigKind
    public let name: String

    public init(kind: ConfigKind, name: String) {
        self.kind = kind
        self.name = name
    }

    public var id: String {
        "\(kind.rawValue)|\(name)"
    }
}

/// One item in one version (History › item).
public struct SpaceItemVersionModel: Sendable, Hashable, Identifiable {
    public let version: Int64
    public let authorName: String
    public let createdAt: Date
    /// The short fingerprint every member sees for this value; nil when removed or unknown.
    public let fingerprint: String?
    public let isRemoved: Bool

    public var id: Int64 {
        version
    }
}

/// What applying a teammate's version did to the vault (S8).
public struct SpaceApplyResultModel: Sendable, Hashable {
    /// Items whose value or presence changed.
    public var updated = 0
    /// Items with a local pending edit that a teammate's version also changed: the edit stays a
    /// draft, published on top at the next Sync (Keep Mine); History › Restore takes theirs.
    public var conflictNames: [String] = []

    public init(updated: Int = 0, conflictNames: [String] = []) {
        self.updated = updated
        self.conflictNames = conflictNames
    }
}

/// What receiving one version from a teammate did.
public enum SpaceReceiveOutcomeModel: Sendable, Hashable {
    /// Verified, stored and applied; `version` is the new head.
    case stored(spaceID: SpaceID, version: Int64, applied: SpaceApplyResultModel)
    /// This Mac has them already.
    case alreadyHave
    /// They do not follow this Mac's head (fetch the missing ones first), or a new space's log
    /// does not start at version 1.
    case gap
    /// Another version with the same number: two members published at once.
    case forked
    /// This Mac is publishing in that space right now; try again after.
    case busy
    /// A space for a repository or environment this vault does not have.
    case repositoryMissing
    /// A new space whose members do not include this device.
    case notAMember
    /// The scope is already shared here under another space.
    case scopeAlreadyShared
}

/// What to do after removing members (S7): cryptography only cuts future access.
public struct SpaceRotationChecklistModel: Sendable, Hashable {
    /// Every secret the removed devices received in any version: rotate them on GitHub.
    public let secretNames: [String]
}
