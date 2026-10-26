import Foundation
import VaultCore

nonisolated extension RepoCapabilityModel.ReadOnlyReason {
    /// Why a scope is read-only (§10 "read-only scopes explain why").
    var localizedExplanation: String {
        switch self {
        case .archived:
            String(
                localized: "capability.explanation.archived",
                defaultValue: "This repository is archived on GitHub, so its secrets and variables cannot change. Unarchive it on GitHub to edit them."
            )
        case .adminRequired:
            String(
                localized: "capability.explanation.adminRequired",
                defaultValue: "Changing this scope needs admin rights on the repository. You can still reveal and copy values you have."
            )
        case .unavailable:
            String(
                localized: "capability.explanation.unavailable",
                defaultValue: "GitHub could not be read for this repository (SAML authorization, removed, or no longer shared). Refresh after fixing access."
            )
        }
    }
}

nonisolated extension DeploymentBranchPolicyModel {
    /// "All branches", "Protected branches only" or "Selected (2 rules)" (§10 Column 3).
    var localizedSummary: String {
        switch self {
        case .all:
            String(localized: "branchPolicy.all", defaultValue: "All branches")
        case .protectedBranches:
            String(localized: "branchPolicy.protected", defaultValue: "Protected branches only")
        case .custom:
            String(localized: "branchPolicy.custom", defaultValue: "Selected (\(activePatterns.count) rules)")
        }
    }
}

nonisolated extension RepoVisibility {
    var localizedTitle: String {
        switch self {
        case .public: String(localized: "visibility.public", defaultValue: "Public")
        case .private: String(localized: "visibility.private", defaultValue: "Private")
        case .internal: String(localized: "visibility.internal", defaultValue: "Internal")
        }
    }
}
