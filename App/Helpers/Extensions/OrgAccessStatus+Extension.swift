import GitHubKit
import SwiftUI

extension OrgAccessStatus {
    /// The organization's access in Preferences › Accounts and Connect (1.0, B4; D1's wording).
    var title: String {
        switch self {
        case .ready:
            String(localized: "accounts.org.ready", defaultValue: "Ready")
        case .needsAdminOrgScope:
            String(localized: "accounts.org.needsAdminOrg", defaultValue: "Needs admin:org")
        case .needsOrgAdmin:
            String(localized: "accounts.org.needsOrgAdmin", defaultValue: "Org secrets need an org admin")
        case .ssoRequired:
            String(localized: "accounts.org.sso", defaultValue: "Needs SSO authorization")
        case .unknown:
            String(localized: "accounts.org.unknown", defaultValue: "Access unknown")
        }
    }

    var tint: Color {
        switch self {
        case .ready: Theme.Colors.success
        case .needsAdminOrgScope, .ssoRequired: Theme.Colors.warning
        case .needsOrgAdmin, .unknown: Theme.Colors.mutedText
        }
    }

    /// The organization's mark in Preferences › Accounts (board Settings-Accounts): a ring where
    /// the user can act (a scope, SSO), grey where only an org admin can.
    var mark: PreferencesStatus.Mark {
        switch self {
        case .ready: .fine
        case .needsAdminOrgScope, .ssoRequired: .needsYou
        case .needsOrgAdmin, .unknown: .idle
        }
    }

    /// GitHub's SSO authorization page, when gh printed one.
    var ssoURL: URL? {
        if case .ssoRequired(let url) = self { return url }
        return nil
    }
}
