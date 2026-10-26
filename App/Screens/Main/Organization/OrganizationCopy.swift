import Foundation

/// The organization view's texts (1.0, mockups Org-Visibility and Org-UsedBy).
enum OrganizationCopy {
    /// One key with the place header's kind.
    static let eyebrow = PlaceCopy.organization
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
    static let refreshFailedTitle = String(localized: "organization.refresh.failed", defaultValue: "Organization not refreshed")
    /// Accept GitHub of a secret whose date moved: no fill step follows, unlike a repository's.
    static let acceptSecretChange = String(
        localized: "organization.drift.acceptSecret",
        defaultValue: "Your vault takes GitHub's access. GitHub never returns secret values, so its value is missing until you enter it."
    )
    /// Accept GitHub of a secret whose date stands: only who can use it changed.
    static let acceptAccessChange = String(
        localized: "organization.drift.acceptAccess",
        defaultValue: "Your vault takes GitHub's access; the value stays."
    )

    static func removeMessage(_ login: String) -> String {
        String(
            localized: "organization.remove.message",
            defaultValue: "\(login)'s secrets and variables are deleted from this Mac. Nothing changes on GitHub."
        )
    }
}
