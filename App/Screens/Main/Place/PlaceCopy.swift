import Foundation
import VaultCore

/// The texts of a place's header and its ⋯ More menu (1.0 D6c3; boards Main2-Repository,
/// Main2-Actions, Place-Table, KV-Place, Folder-View, Org-Visibility).
nonisolated enum PlaceCopy {
    static let repository = String(localized: "place.kind.repository", defaultValue: "Repository")
    static let environment = String(localized: "place.kind.environment", defaultValue: "Environment")
    static let organization = String(localized: "place.kind.organization", defaultValue: "Organization")
    static let folder = String(localized: "place.kind.folder", defaultValue: "Folder")
    static let folderNote = String(localized: "place.folder.note", defaultValue: "never sent anywhere by itself")
    static let createdByNextSync = String(localized: "place.createdByNextSync", defaultValue: "created by the next Sync")
    static let more = String(localized: "place.more", defaultValue: "More")
    static let pasteMultiple = String(localized: "place.more.pasteMultiple", defaultValue: "Paste Multiple…")
    static let importEnv = String(localized: "place.more.importEnv", defaultValue: "Import .env…")
    static let exportEnv = String(localized: "place.more.exportEnv", defaultValue: "Export .env…")
    static let copyTo = String(localized: "place.more.copyTo", defaultValue: "Copy To")
    static let shareSecurely = String(localized: "place.more.shareSecurely", defaultValue: "Share Securely…")
    static let deploymentBranches = String(localized: "place.more.deploymentBranches", defaultValue: "Deployment Branches…")
    static let clone = String(localized: "place.more.clone", defaultValue: "Clone…")
    static let refresh = String(localized: "place.more.refresh", defaultValue: "Refresh")
    static let refreshing = String(localized: "place.refreshing", defaultValue: "Refreshing…")
    static let deleteSelected = String(localized: "place.more.deleteSelected", defaultValue: "Delete Selected…")
    static let review = String(localized: "place.drift.review", defaultValue: "Review")

    static func newItem(_ kind: ConfigKind) -> String {
        switch kind {
        case .secret: String(localized: "place.more.newSecret", defaultValue: "New Secret")
        case .variable: String(localized: "place.more.newVariable", defaultValue: "New Variable")
        }
    }

    /// "Environment · api-service · 6 secrets · 2 variables · 1 without value": the parts that are
    /// set, in order.
    static func subline(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "6 secrets · 2 variables · 1 without value" (inflected). `variables` is nil for a place
    /// that holds secrets only (a Key Vault); "without value" shows only when some secret lacks one.
    /// `omitsZeroKinds` leaves out a kind with none, and nothing is "" (a share file's counts).
    static func counts(secrets: Int, variables: Int?, withoutValue: Int = 0, omitsZeroKinds: Bool = false) -> String {
        let secretsText = omitsZeroKinds && secrets == 0 ? nil : String(inflected: AttributedString(
            localized: "place.counts.secrets",
            defaultValue: "^[\(secrets) secret](inflect: true)"
        ))
        let variablesText = variables.flatMap { count in
            omitsZeroKinds && count == 0 ? nil : String(inflected: AttributedString(
                localized: "place.counts.variables",
                defaultValue: "^[\(count) variable](inflect: true)"
            ))
        }
        let withoutValueText = withoutValue > 0
            ? String(localized: "place.counts.withoutValue", defaultValue: "\(withoutValue) without value")
            : nil
        return subline([secretsText, variablesText, withoutValueText])
    }

    /// "2 changed on GitHub" (board Main2-Repository).
    static func changedOnGitHub(_ count: Int) -> String {
        String(localized: "place.drift.changed", defaultValue: "\(count) changed on GitHub")
    }
}
