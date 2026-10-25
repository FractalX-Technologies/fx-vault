import Foundation
import GitHubKit
import VaultCore

/// One pending organization change in a Sync review (1.0, tasks/todo.md B6b). Names only.
public struct OrgChangeModel: Sendable, Hashable, Identifiable {
    public enum Operation: String, Sendable, Hashable {
        case add, update, delete
    }

    public var id: ConfigItemID { itemID }
    public let itemID: ConfigItemID
    public let name: String
    public let kind: ConfigKind
    public let operation: Operation
    /// The visibility the write sends (the synced one for a deletion).
    public let visibility: OrgVisibility

    public init(itemID: ConfigItemID, name: String, kind: ConfigKind, operation: Operation, visibility: OrgVisibility) {
        self.itemID = itemID
        self.name = name
        self.kind = kind
        self.operation = operation
        self.visibility = visibility
    }
}

/// Why an organization change cannot be sent.
public enum OrgBlockReason: Sendable, Hashable {
    /// An add whose name GitHub already has.
    case existsRemotely
    /// GitHub changed or removed the item since the vault last read it.
    case remoteChanged
    /// A secret write needs its value, and GitHub never returned it: fill it in first.
    case valueMissing
    /// A `selected` item reaches no repository: GitHub cannot be told an empty list.
    case noRepositories
    /// The organization's secrets or variables could not be listed.
    case listingFailed(GHError)
}

public struct OrgBlockedChangeModel: Sendable, Hashable, Identifiable {
    public var id: ConfigItemID { change.itemID }
    public let change: OrgChangeModel
    public let reason: OrgBlockReason

    public init(change: OrgChangeModel, reason: OrgBlockReason) {
        self.change = change
        self.reason = reason
    }
}

/// The pending changes of one organization, checked against GitHub's listing.
public struct OrgReviewModel: Sendable, Hashable {
    public let organizationID: OrganizationID
    public let login: String
    /// Sendable changes: writes first, deletions last, then by name.
    public let changes: [OrgChangeModel]
    public let blocked: [OrgBlockedChangeModel]

    public init(organizationID: OrganizationID, login: String, changes: [OrgChangeModel], blocked: [OrgBlockedChangeModel]) {
        self.organizationID = organizationID
        self.login = login
        self.changes = changes
        self.blocked = blocked
    }

    public var isEmpty: Bool { changes.isEmpty && blocked.isEmpty }
    public var deletions: [OrgChangeModel] { changes.filter { $0.operation == .delete } }
    public var writes: [OrgChangeModel] { changes.filter { $0.operation != .delete } }
}

public enum OrgChangeOutcome: Sendable, Hashable {
    /// Sent and seen in the confirming listing (or already gone, for a deletion).
    case done
    /// Sent, but the confirming listing did not show it: the next Sync sends it again.
    case unconfirmed
    case failed(GHError)
    case blocked(OrgBlockReason)
    /// Not run: a deletion left out, a cancelled run, or a row that changed since the review.
    case skipped
}

public struct OrgRunResultModel: Sendable, Hashable {
    public var outcomes: [ConfigItemID: OrgChangeOutcome]

    public init(outcomes: [ConfigItemID: OrgChangeOutcome] = [:]) {
        self.outcomes = outcomes
    }

    public var doneCount: Int { outcomes.values.filter { $0 == .done }.count }
    public var failedCount: Int { outcomes.values.filter { if case .failed = $0 { true } else { false } }.count }
}
