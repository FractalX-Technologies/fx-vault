import SharingKit
import VaultCore

/// A one-line description of a deployment branch policy for the "Deployment branches differ"
/// row (§9.5).
extension ShareBranchPolicyModel {
    var localizedSummary: String {
        switch type {
        case .all:
            String(localized: "share.policy.all", defaultValue: "All branches")
        case .protected:
            String(localized: "share.policy.protected", defaultValue: "Protected branches only")
        case .custom:
            String(
                localized: "share.policy.custom",
                defaultValue: "Selected branches and tags (\(patterns.count) rules)"
            )
        }
    }

    /// The rules, one per line (`branch: release/*`).
    var localizedPatterns: [String] {
        patterns.map { pattern in
            switch pattern.type {
            case .branch:
                String(localized: "share.policy.pattern.branch", defaultValue: "Branch: \(pattern.name)")
            case .tag:
                String(localized: "share.policy.pattern.tag", defaultValue: "Tag: \(pattern.name)")
            }
        }
    }
}
