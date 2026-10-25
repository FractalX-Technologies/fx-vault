import Foundation

/// A6 `user/memberships/orgs/{org}`: the fields FX Vault reads.
public struct GHOrgMembershipDTO: Decodable, Sendable, Hashable {
    /// `active` or `pending` (an invitation not accepted yet).
    public let state: String
    /// `admin` or `member`.
    public let role: String

    public init(state: String, role: String) {
        self.state = state
        self.role = role
    }

    public var isActiveAdmin: Bool {
        state == "active" && role == "admin"
    }
}
