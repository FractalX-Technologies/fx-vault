import Foundation
import VaultCore

/// Shared spaces as the sync engine sees them (v0.6.0, tasks/todo.md S5): the gate before a
/// push and the version after it. VaultData implements it over the verified space log; the
/// engine never sees keys, members or versions, only marker texts and decisions.
///
/// The order for each shared scope a run writes (Bryan's rule: sync first, verify, then push):
/// 1. preflight lists the scope (B8/B9, the marker split off) and asks ``gate(spaceID:markerText:)``;
///    any decision but `.clear`/`.ahead` blocks every item change of the scope;
/// 2. the executor writes ``claim(spaceID:)`` as the marker and re-reads it before the scope's
///    first write; a different marker stops the scope;
/// 3. after the repository's steps, it writes ``publish(spaceID:reason:tookOverFrom:)`` and
///    re-reads it.
public protocol SyncSpaceCoordinating: Sendable {
    /// The shared scopes of `repositoryID` (empty when none).
    func sharedScopes(repositoryID: RepoID) throws(SyncError) -> [SyncSharedScopeModel]
    /// GitHub's marker (nil when the scope lists none) against this Mac's verified head.
    func gate(spaceID: SpaceID, markerText: String?) throws(SyncError) -> SpaceGateDecision
    /// Records the claim of the next version and returns the `publishing` marker to write.
    func claim(spaceID: SpaceID) throws(SyncError) -> String
    /// Records the version of what GitHub now holds (none when nothing changed) and returns the
    /// `published` marker to write. The claim ends. `reason` ("What changed?") and a takeover
    /// (Q3: the member whose stale claim this run replaced) are recorded in the version.
    func publish(spaceID: SpaceID, reason: String?, tookOverFrom: String?) throws(SyncError) -> String
    /// The `published` marker was confirmed on GitHub: the claim is finished.
    func confirmPublished(spaceID: SpaceID) throws(SyncError)
    /// Ends a claim without a version (it was lost to another member's marker).
    func abandonClaim(spaceID: SpaceID) throws(SyncError)
}

/// One shared scope of a repository.
public struct SyncSharedScopeModel: Sendable, Hashable {
    public let spaceID: SpaceID
    public let scope: ConfigScope
    /// This Mac claimed a version whose `published` marker is not confirmed on GitHub yet.
    public let hasUnfinishedClaim: Bool

    public init(spaceID: SpaceID, scope: ConfigScope, hasUnfinishedClaim: Bool = false) {
        self.spaceID = spaceID
        self.scope = scope
        self.hasUnfinishedClaim = hasUnfinishedClaim
    }
}

/// A shared scope's gate in a preflight: why it is blocked, or how the executor claims it.
public struct SyncSpaceGateModel: Sendable, Hashable {
    public let spaceID: SpaceID
    public let scope: ConfigScope
    public let decision: SpaceGateDecision
    /// GitHub lists a marker in the scope already (writing it is an update).
    public let hasMarker: Bool
    /// The member whose stale claim the user chose to take over (Q3); recorded in the version.
    public let takenOverFrom: String?

    public init(spaceID: SpaceID, scope: ConfigScope, decision: SpaceGateDecision, hasMarker: Bool, takenOverFrom: String? = nil) {
        self.spaceID = spaceID
        self.scope = scope
        self.decision = decision
        self.hasMarker = hasMarker
        self.takenOverFrom = takenOverFrom
    }

    /// The executor claims this scope before writing to it.
    public var allowsPush: Bool {
        decision.allowsPush || takenOverFrom != nil
    }
}

/// Why a shared scope's changes did not run.
public struct SyncSpaceBlockModel: Sendable, Hashable {
    public let spaceID: SpaceID
    public let decision: SpaceGateDecision

    public init(spaceID: SpaceID, decision: SpaceGateDecision) {
        self.spaceID = spaceID
        self.decision = decision
    }
}
