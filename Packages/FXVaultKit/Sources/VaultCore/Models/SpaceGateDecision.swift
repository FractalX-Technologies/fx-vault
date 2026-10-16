import Foundation

/// What the gate decided for one shared scope before a push (v0.6.0, S5). SharingKit's
/// `SpaceGate` decides it; SyncEngine blocks a scope on it.
public enum SpaceGateDecision: Sendable, Hashable {
    /// GitHub's marker names this Mac's head (or there is no marker yet): claim and push.
    case clear
    /// This Mac holds versions GitHub's marker does not name yet (a publish that did not finish):
    /// claim on top of them.
    case ahead
    /// A member published versions this Mac does not have: get them first (Q1, strict).
    case behind(version: UInt64, login: String)
    /// A member is publishing right now. `isStale` after `SpaceProtocol.claimStaleAfter`: it may
    /// be taken over after a confirmation (Q3).
    case publishing(login: String, since: Date, isStale: Bool)
    /// The marker names this version number with another hash: two members published at once.
    case forked
    /// The marker is unreadable or not signed by a member.
    case invalidMarker
    /// This Mac is no longer a member of the space: it cannot publish versions.
    case notAMember
}

extension SpaceGateDecision {
    /// True when the scope may be claimed and pushed.
    public var allowsPush: Bool {
        switch self {
        case .clear, .ahead: true
        case .behind, .publishing, .forked, .invalidMarker, .notAMember: false
        }
    }
}
