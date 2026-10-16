import DestinationKit
import Foundation
import VaultCore
import VaultStore

// MARK: - Review (R5)

/// One pending write to a destination: names only.
public struct DestinationChangeModel: Sendable, Hashable, Identifiable {
    public let destinationID: DestinationID
    public let itemID: ConfigItemID
    /// FX Vault's name.
    public let name: String
    /// The name the provider stores (`DATABASE-URL` in Key Vault).
    public let remoteName: String
    public let kind: ConfigKind
    public let operation: DestinationPendingOperation
    /// Vercel: the variable's other environments, which an update changes too and a delete
    /// leaves in place.
    public let otherEnvironments: [VercelEnvironment]

    public init(
        destinationID: DestinationID,
        itemID: ConfigItemID,
        name: String,
        remoteName: String,
        kind: ConfigKind,
        operation: DestinationPendingOperation,
        otherEnvironments: [VercelEnvironment] = []
    ) {
        self.destinationID = destinationID
        self.itemID = itemID
        self.name = name
        self.remoteName = remoteName
        self.kind = kind
        self.operation = operation
        self.otherEnvironments = otherEnvironments
    }

    public var id: String {
        "\(destinationID.uuidString)|\(itemID.uuidString)"
    }
}

/// Why a destination change cannot be sent now.
public enum DestinationBlockReason: Sendable, Hashable {
    /// The value is not in the vault (a write-only remote value that was never filled).
    case valueMissing
    /// The destination has no connection (Supabase, Vercel): choose or add one.
    case connectionMissing
    /// The destination could not be listed, so nothing is sent to it.
    case listingFailed(DestinationError)
    /// The item changed or disappeared remotely since the last sync: Refresh and review.
    case remoteChanged
    /// A new item whose name the remote already has: Refresh and review.
    case existsRemotely
    /// A public name (`NEXT_PUBLIC_…`) whose value looks like a secret token, private key or URL
    /// with a password (R10): change the value, or Mark as Public.
    case publicCredential(prefix: String)
    /// The name breaks the provider's rules.
    case invalidName(ValidationError)
}

/// A change that stays pending, with the reason.
public struct DestinationBlockedChangeModel: Sendable, Hashable, Identifiable {
    public let change: DestinationChangeModel
    public let reason: DestinationBlockReason

    public init(change: DestinationChangeModel, reason: DestinationBlockReason) {
        self.change = change
        self.reason = reason
    }

    public var id: String {
        change.id
    }
}

/// A note for the review that does not block (R10): a public name whose value looks like a token
/// (a JWT or a long random string), which is fine for keys meant to be public.
public struct DestinationReviewWarningModel: Sendable, Hashable, Identifiable {
    public let itemID: ConfigItemID
    public let name: String
    public let prefix: String

    public init(itemID: ConfigItemID, name: String, prefix: String) {
        self.itemID = itemID
        self.name = name
        self.prefix = prefix
    }

    public var id: ConfigItemID {
        itemID
    }
}

/// The review of one destination.
public struct DestinationReviewSectionModel: Sendable, Hashable, Identifiable {
    public let destination: DestinationModel
    /// Sendable changes, adds and updates first, then deletions.
    public let changes: [DestinationChangeModel]
    public let blocked: [DestinationBlockedChangeModel]
    public let warnings: [DestinationReviewWarningModel]

    public init(
        destination: DestinationModel,
        changes: [DestinationChangeModel],
        blocked: [DestinationBlockedChangeModel],
        warnings: [DestinationReviewWarningModel]
    ) {
        self.destination = destination
        self.changes = changes
        self.blocked = blocked
        self.warnings = warnings
    }

    public var id: DestinationID {
        destination.id
    }

    public var deletions: [DestinationChangeModel] {
        changes.filter { $0.operation == .delete }
    }

    public var writes: [DestinationChangeModel] {
        changes.filter { $0.operation != .delete }
    }
}

/// The destination part of the Sync review of one repository.
public struct DestinationReviewModel: Sendable, Hashable {
    public let repositoryID: RepoID
    /// Destinations with pending changes, in the sidebar order.
    public let sections: [DestinationReviewSectionModel]

    public init(repositoryID: RepoID, sections: [DestinationReviewSectionModel]) {
        self.repositoryID = repositoryID
        self.sections = sections
    }

    public static func empty(_ repositoryID: RepoID) -> DestinationReviewModel {
        DestinationReviewModel(repositoryID: repositoryID, sections: [])
    }

    /// Every pending change, sendable or not.
    public var pendingCount: Int {
        sections.reduce(0) { $0 + $1.changes.count + $1.blocked.count }
    }

    /// Changes the Sync can send.
    public var executableCount: Int {
        sections.reduce(0) { $0 + $1.changes.count }
    }

    public var deletions: [DestinationChangeModel] {
        sections.flatMap(\.deletions)
    }

    public var isEmpty: Bool {
        pendingCount == 0
    }
}

// MARK: - Run

/// What happened to one change.
public enum DestinationChangeOutcome: Sendable, Hashable {
    /// Written and confirmed by re-listing (or by the provider's answer).
    case done
    /// Written, but the re-list did not confirm it yet: pushed again on the next Sync.
    case unconfirmed
    case failed(DestinationError)
    /// Became blocked when the destination was listed again before writing.
    case blocked(DestinationBlockReason)
    /// Not attempted (a deletion that was not confirmed, or the run was cancelled).
    case skipped
}

/// One step of a running destination sync.
public enum DestinationProgressEvent: Sendable, Hashable {
    case started(changeID: String)
    case finished(changeID: String, outcome: DestinationChangeOutcome)
}

/// The outcome of a destination sync run.
public struct DestinationRunResultModel: Sendable, Hashable {
    public var outcomes: [String: DestinationChangeOutcome]

    public init(outcomes: [String: DestinationChangeOutcome] = [:]) {
        self.outcomes = outcomes
    }

    public var doneCount: Int {
        outcomes.values.count { $0 == .done || $0 == .unconfirmed }
    }

    public var failedCount: Int {
        outcomes.values.count {
            if case .failed = $0 { return true }
            return false
        }
    }

    public var blockedCount: Int {
        outcomes.values.count {
            if case .blocked = $0 { return true }
            return false
        }
    }
}

// MARK: - Refresh and drift (R6)

/// How a destination differs from what the vault last synced.
public enum DestinationDriftKind: String, Sendable, Hashable, CaseIterable {
    /// The remote has an item the vault does not.
    case remoteAdded
    /// The remote's value (or type) changed since the last sync.
    case remoteChanged
    /// The remote no longer has a synced item.
    case remoteDeleted
}

/// One difference found by Refresh.
public struct DestinationDriftModel: Sendable, Hashable, Identifiable {
    public let destinationID: DestinationID
    public let kind: DestinationDriftKind
    public let name: String
    public let remoteName: String
    /// The vault's row, or nil for a remote add.
    public let itemID: ConfigItemID?
    /// The kind the remote has (adds and changes).
    public let remoteKind: ConfigKind?
    /// Whether "Use Remote" brings the value (false for Supabase and Vercel sensitive values:
    /// the value becomes missing).
    public let isValueReadable: Bool
    /// Whether "Keep Mine" is possible (a remote change of an item whose value the vault
    /// does not have cannot be kept).
    public let canKeepMine: Bool

    public init(
        destinationID: DestinationID,
        kind: DestinationDriftKind,
        name: String,
        remoteName: String,
        itemID: ConfigItemID?,
        remoteKind: ConfigKind?,
        isValueReadable: Bool,
        canKeepMine: Bool
    ) {
        self.destinationID = destinationID
        self.kind = kind
        self.name = name
        self.remoteName = remoteName
        self.itemID = itemID
        self.remoteKind = remoteKind
        self.isValueReadable = isValueReadable
        self.canKeepMine = canKeepMine
    }

    public var id: String {
        "\(destinationID.uuidString)|\(kind.rawValue)|\(name)"
    }
}

/// How the user resolves a drift finding.
public enum DestinationDriftChoice: Sendable, Hashable {
    /// The vault wins: the next Sync sends it (or deletes the remote add).
    case keepMine
    /// The remote wins: the vault takes its value, its deletion or its new item.
    case useRemote
}

/// A remote item FX Vault cannot use, listed with the reason (never dropped silently).
public struct DestinationUnusableItemModel: Sendable, Hashable, Identifiable {
    public let remoteName: String
    public let reason: DestinationUnusableReason

    public init(remoteName: String, reason: DestinationUnusableReason) {
        self.remoteName = remoteName
        self.reason = reason
    }

    public var id: String {
        remoteName
    }
}

/// The result of listing one destination.
public struct DestinationRefreshModel: Sendable, Hashable {
    public let destinationID: DestinationID
    public let findings: [DestinationDriftModel]
    public let unusable: [DestinationUnusableItemModel]
    public let listedAt: Date

    public init(destinationID: DestinationID, findings: [DestinationDriftModel], unusable: [DestinationUnusableItemModel], listedAt: Date) {
        self.destinationID = destinationID
        self.findings = findings
        self.unusable = unusable
        self.listedAt = listedAt
    }
}

/// The result of importing what a new destination already holds.
public struct DestinationImportResultModel: Sendable, Hashable {
    public var imported: [String] = []
    /// Imported without a value (write-only remote values).
    public var withoutValue: [String] = []
    /// Names the vault already had a pending item for (left for Refresh to review).
    public var conflicts: [String] = []
    public var unusable: [DestinationUnusableItemModel] = []

    public init() {}
}

/// Errors of ``DestinationSyncRepository``.
public enum DestinationSyncError: Error, Sendable, Hashable {
    case config(ConfigRepositoryError)
    case remote(DestinationError)
    /// The destination needs a connection it does not have.
    case connectionMissing
    /// The remote changed while the user was deciding: Refresh again.
    case stale
}
