import Foundation

/// A paired device (v0.5.0, tasks/todo.md T2) as lists show it: no keys. The login and names
/// are what the other person's Mac sent when pairing (unverified, sanitized).
public struct TeammateModel: Sendable, Hashable, Identifiable {
    /// The device id, lowercase hex (32 characters).
    public var id: String
    public var login: String
    public var displayName: String
    public var macName: String
    public var pairedAt: Date
    /// When this Mac last saw the teammate nearby (presence), or nil.
    public var lastSeenAt: Date?
    /// Pings from this teammate make no sound and post nothing.
    public var isMuted: Bool
    /// This Mac's announce key changed since the teammate last received its card.
    public var needsCardUpdate: Bool
    /// How the two Macs paired (v0.9.0).
    public var pairedVia: TeammatePairing
    /// False while this Mac does not know the teammate's announce key (v0.9.0): an inviter
    /// paired remotely sends it later, in a teammates file or a nearby card update. Until then
    /// the teammate never shows as nearby here.
    public var hasAnnounceKey: Bool

    public init(
        id: String,
        login: String,
        displayName: String,
        macName: String,
        pairedAt: Date,
        lastSeenAt: Date? = nil,
        isMuted: Bool = false,
        needsCardUpdate: Bool = false,
        pairedVia: TeammatePairing = .nearby,
        hasAnnounceKey: Bool = true
    ) {
        self.id = id
        self.login = login
        self.displayName = displayName
        self.macName = macName
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.isMuted = isMuted
        self.needsCardUpdate = needsCardUpdate
        self.pairedVia = pairedVia
        self.hasAnnounceKey = hasAnnounceKey
    }

    /// The name to show: the display name, else the login, else the Mac name.
    public var name: String {
        [displayName, login, macName].first { !$0.isEmpty } ?? id
    }
}

/// How a teammate was paired (`teammates.paired_via`, v0.9.0).
public enum TeammatePairing: String, Sendable, Hashable, CaseIterable, Codable {
    /// Add Teammate with both Macs on the same network (the 6-digit code, v0.5.0).
    case nearby
    /// Add Teammate › Not Nearby…: card files and a 6-word code compared on a call (v0.9.0).
    case remote
}
