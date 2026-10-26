import Foundation
import GitHubKit

/// The sidebar tree's texts (1.0; boards Main2-Home, Main2-Expanded).
enum SidebarCopy {
    static let searchPrompt = String(localized: "main.sidebar.search.prompt", defaultValue: "Search")
    static let searchLabel = String(localized: "main.sidebar.search.label", defaultValue: "Search the sidebar")
    static let searchShortcut = String(localized: "main.sidebar.search.shortcut", defaultValue: "Search the sidebar (⌘F)")
    /// The section of the Key Vaults, and the first step of their toolbar path; Sync and
    /// Connect say "Azure Key Vault".
    static let azureSection = String(localized: "main.sidebar.azure", defaultValue: "Azure")
    static let expanded = String(localized: "main.sidebar.owner.expanded", defaultValue: "Expanded")
    static let collapsed = String(localized: "main.sidebar.owner.collapsed", defaultValue: "Collapsed")
    static let pending = String(localized: "main.scopes.pending.help", defaultValue: "Pending changes")
    static let lock = String(localized: "main.sidebar.lock", defaultValue: "Lock FX Vault (⌃⌘L)")
    static let settings = String(localized: "main.sidebar.settings", defaultValue: "Settings")
    static let addByName = String(localized: "main.sidebar.addByName.menu", defaultValue: "Add Repository by Name…")
    static let newEnvironment = String(localized: "main.scopes.newEnvironment.menu", defaultValue: "New Environment…")

    /// The help of a count of secrets without a value (a repository, a scope, a Key Vault).
    static func valueMissingHelp(_ count: Int) -> String {
        String(inflected: AttributedString(
            localized: "main.scopes.valueMissing.help",
            defaultValue: "^[\(count) secret](inflect: true) without a value in FX Vault"
        ))
    }

    static func expand(_ name: String) -> String {
        String(localized: "main.sidebar.expand", defaultValue: "Show what is in \(name)")
    }

    static func collapse(_ name: String) -> String {
        String(localized: "main.sidebar.collapse", defaultValue: "Hide what is in \(name)")
    }

    /// A repository's chevron: it opens the repository, whose environments show under it.
    static func openRepository(_ name: String) -> String {
        String(localized: "main.sidebar.openRepository", defaultValue: "Open \(name)")
    }

    static func showMore(_ count: Int) -> String {
        String(localized: "main.sidebar.showMore", defaultValue: "Show \(count) more")
    }

    // MARK: - Owner problems

    /// The subline's text and the title of its action, if it has one.
    static func subline(_ problem: SidebarOwnerProblem) -> (text: String, action: String?) {
        switch problem {
        case .signedOut:
            (String(localized: "main.sidebar.notLoggedIn", defaultValue: "Not logged in"), openSettings)
        case .missingScopes(let scopes):
            (
                String(localized: "main.sidebar.needsScopes", defaultValue: "Needs \(scopes.joined(separator: ", "))"),
                approve
            )
        case .needsAdminOrg:
            (OrgAccessStatus.needsAdminOrgScope.title, approve)
        case .needsOrgAdmin:
            (OrgAccessStatus.needsOrgAdmin.title, nil)
        case .ssoRequired:
            (String(localized: "main.sidebar.authorizeSSO", defaultValue: "Authorize SSO"), open)
        case .unavailable:
            (String(localized: "main.sidebar.ownerUnavailable", defaultValue: "Could not be listed"), nil)
        }
    }

    private static let approve = String(localized: "main.sidebar.approve", defaultValue: "Approve")
    private static let open = String(localized: "main.sidebar.open", defaultValue: "Open")
    private static let openSettings = String(localized: "main.sidebar.openSettings", defaultValue: "Settings")
}
