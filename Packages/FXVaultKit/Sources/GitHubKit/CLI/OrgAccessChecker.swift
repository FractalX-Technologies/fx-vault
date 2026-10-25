import Foundation

/// Whether an account can manage one organization's secrets and variables (1.0, tasks/todo.md
/// B4). GitHub needs both the `admin:org` scope on the token and the organization's admin role.
public enum OrgAccessStatus: Sendable, Hashable {
    case ready
    /// The token lacks `admin:org`; `gh auth refresh -s admin:org` adds it.
    case needsAdminOrgScope
    /// The account is a member, not an owner: no scope fixes that, an owner must manage them.
    case needsOrgAdmin
    /// The organization enforces SAML SSO and the token is not authorized for it; the URL is
    /// GitHub's authorization page when gh printed one.
    case ssoRequired(URL?)
    /// A fine-grained token (no scope list) or a role that could not be read.
    case unknown
}

public enum OrgAccessChecker {
    /// - Parameters:
    ///   - scopes: the account's parsed scopes (`GHAccountStatusModel.scopeList`); nil when unknown.
    ///   - membership: A6 for the organization.
    public static func status(scopes: [String]?, membership: Result<GHOrgMembershipDTO, GHError>) -> OrgAccessStatus {
        switch membership {
        case .failure(.samlRequired(let url)):
            return .ssoRequired(url)
        // The role decides first: approving a scope never helps a member.
        case .success(let membership) where !membership.isActiveAdmin:
            return .needsOrgAdmin
        case .success:
            guard let scopes else { return .unknown }
            return scopes.contains(ScopeChecker.adminOrgScope) ? .ready : .needsAdminOrgScope
        case .failure:
            guard let scopes, !scopes.contains(ScopeChecker.adminOrgScope) else { return .unknown }
            return .needsAdminOrgScope
        }
    }
}
