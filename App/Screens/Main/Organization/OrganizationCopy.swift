import Foundation

/// The organization view's texts (1.0, mockups Org-Visibility and Org-UsedBy).
enum OrganizationCopy {
    static let eyebrow = String(localized: "organization.eyebrow", defaultValue: "Organization")
    static let rowTitle = String(localized: "organization.row", defaultValue: "Secrets and variables")
    static let importMessage = String(
        localized: "organization.import.message",
        defaultValue: "Import this organization's own secrets and variables. Secrets arrive without values: GitHub never returns them. Reading them needs admin:org and the organization's admin role."
    )
    static let importButton = String(localized: "organization.import.button", defaultValue: "Import")
    static let remove = String(localized: "organization.remove", defaultValue: "Remove from Vault…")
    static let removeTitle = String(localized: "organization.remove.title", defaultValue: "Remove this organization from FX Vault?")
    static let removeConfirm = String(localized: "organization.remove.confirm", defaultValue: "Remove from Vault")
    static let kind = String(localized: "organization.table.kind", defaultValue: "Kind")
    static let visibility = String(localized: "organization.table.visibility", defaultValue: "Visibility")
    static let access = String(localized: "organization.editor.access", defaultValue: "Access")
    static let noRepositories = String(
        localized: "organization.editor.access.noRepositories",
        defaultValue: "No repositories of this organization are listed in the sidebar."
    )
    static let revertAccess = String(localized: "organization.table.revertAccess", defaultValue: "Revert Access")
    static let empty = String(localized: "organization.table.empty", defaultValue: "This organization has no secrets or variables.")

    static func removeMessage(_ login: String) -> String {
        String(
            localized: "organization.remove.message",
            defaultValue: "\(login)'s secrets and variables are deleted from this Mac. Nothing changes on GitHub."
        )
    }

    /// "14 secrets · 6 variables · 3 without value".
    static func counts(secrets: Int, variables: Int, withoutValue: Int) -> String {
        let counts = String(localized: "organization.counts", defaultValue: "\(secrets) secrets · \(variables) variables")
        guard withoutValue > 0 else { return counts }
        return String(localized: "organization.counts.withoutValue", defaultValue: "\(counts) · \(withoutValue) without value")
    }
}
