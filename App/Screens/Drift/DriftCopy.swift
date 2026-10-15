import Foundation
import GitHubKit
import SyncEngine
import VaultCore
import VaultData

/// Every user-facing phrase of the drift banner and review (§7.7). Names and dates only:
/// GitHub never returns secret values, and listed variable values never reach the UI.
nonisolated enum DriftCopy {
    /// "Secret API_TOKEN was changed on GitHub on Oct 12" (§7.7 alert copy).
    static func title(_ drift: DriftModel, date: String?) -> String {
        switch drift.subject {
        case .item(let item):
            let kind = kindTitle(item.kind)
            switch (drift.kind, date) {
            case (.secretModified, let date?), (.variableModified, let date?):
                return String(
                    localized: "drift.finding.modified.date",
                    defaultValue: "\(kind) \(item.name) was changed on GitHub on \(date)"
                )
            case (.remoteAdded, let date?):
                return String(
                    localized: "drift.finding.added.date",
                    defaultValue: "\(kind) \(item.name) was added on GitHub on \(date)"
                )
            case (.remoteAdded, nil):
                return String(localized: "drift.finding.added", defaultValue: "\(kind) \(item.name) was added on GitHub")
            case (.remoteDeleted, _):
                return String(localized: "drift.finding.deleted", defaultValue: "\(kind) \(item.name) was deleted on GitHub")
            default:
                return String(localized: "drift.finding.modified", defaultValue: "\(kind) \(item.name) was changed on GitHub")
            }
        case .environment(let environment):
            switch drift.kind {
            case .environmentAdded:
                return String(
                    localized: "drift.finding.environmentAdded",
                    defaultValue: "Environment \(environment.name) was added on GitHub"
                )
            case .environmentDeleted:
                return String(
                    localized: "drift.finding.environmentDeleted",
                    defaultValue: "Environment \(environment.name) was deleted on GitHub"
                )
            default:
                return String(
                    localized: "drift.finding.policy",
                    defaultValue: "Deployment branches of \(environment.name) were changed on GitHub"
                )
            }
        }
    }

    /// "Secret" or "Variable" at the start of a sentence.
    static func kindTitle(_ kind: ConfigKind) -> String {
        switch kind {
        case .secret: String(localized: "drift.kind.secret", defaultValue: "Secret")
        case .variable: String(localized: "drift.kind.variable", defaultValue: "Variable")
        }
    }

    static func scope(_ drift: DriftModel) -> String {
        switch drift.subject {
        case .item(let item):
            item.environmentName ?? String(localized: "sync.scope.repository", defaultValue: "Repository")
        case .environment:
            String(localized: "drift.scope.environment", defaultValue: "Environment")
        }
    }

    static func systemImage(_ kind: DriftKind) -> String {
        switch kind {
        case .variableModified, .secretModified, .environmentPolicyModified: "pencil.circle"
        case .remoteAdded, .environmentAdded: "plus.circle"
        case .remoteDeleted, .environmentDeleted: "minus.circle"
        }
    }

    static let conflict = String(
        localized: "drift.finding.conflict",
        defaultValue: "Also changed in your vault. Choose which version to keep."
    )

    static func environmentItems(_ names: [String]) -> String {
        String(localized: "drift.finding.environmentItems", defaultValue: "Contains \(names.joined(separator: ", ")).")
    }

    // MARK: - Choices (§7.7 table)

    static let keepLocalTitle = String(localized: "drift.choice.keepLocal", defaultValue: "Keep Local")
    static let acceptGitHubTitle = String(localized: "drift.choice.acceptGitHub", defaultValue: "Accept GitHub")

    /// What "Keep Local" does for this kind of finding.
    static func keepLocalExplanation(_ kind: DriftKind) -> String {
        switch kind {
        case .variableModified, .secretModified:
            String(localized: "drift.keepLocal.modified", defaultValue: "Your value is pushed on the next Sync.")
        case .remoteAdded:
            String(localized: "drift.keepLocal.added", defaultValue: "It is deleted on GitHub on the next Sync.")
        case .remoteDeleted:
            String(localized: "drift.keepLocal.deleted", defaultValue: "It is pushed to GitHub again on the next Sync.")
        case .environmentAdded:
            String(
                localized: "drift.keepLocal.environmentAdded",
                defaultValue: "The environment is deleted on GitHub on the next Sync."
            )
        case .environmentDeleted:
            String(
                localized: "drift.keepLocal.environmentDeleted",
                defaultValue: "The environment and its items are created again on the next Sync."
            )
        case .environmentPolicyModified:
            String(
                localized: "drift.keepLocal.policy",
                defaultValue: "Your deployment branches are pushed on the next Sync."
            )
        }
    }

    /// What "Accept GitHub" does for this kind of finding.
    static func acceptGitHubExplanation(_ kind: DriftKind) -> String {
        switch kind {
        case .variableModified:
            String(localized: "drift.accept.variableModified", defaultValue: "Your vault takes GitHub's value.")
        case .secretModified:
            String(
                localized: "drift.accept.secretModified",
                defaultValue: "GitHub never returns secret values: enter the new value next."
            )
        case .remoteAdded:
            String(
                localized: "drift.accept.added",
                defaultValue: "It is added to your vault (a secret without its value)."
            )
        case .remoteDeleted:
            String(localized: "drift.accept.deleted", defaultValue: "It is deleted from your vault.")
        case .environmentAdded:
            String(
                localized: "drift.accept.environmentAdded",
                defaultValue: "The environment and its items are added to your vault (secrets without values)."
            )
        case .environmentDeleted:
            String(
                localized: "drift.accept.environmentDeleted",
                defaultValue: "The environment and its items are deleted from your vault."
            )
        case .environmentPolicyModified:
            String(localized: "drift.accept.policy", defaultValue: "Your vault takes GitHub's deployment branches.")
        }
    }

    static func unavailable(_ reason: DriftUnavailableReason) -> String {
        switch reason {
        case .valueMissing:
            String(
                localized: "drift.unavailable.valueMissing",
                defaultValue: "Needs the secret's value, which your vault does not have. Fill it first."
            )
        case .conflictsWithPendingRename:
            String(
                localized: "drift.unavailable.pendingRename",
                defaultValue: "A pending environment rename uses this name. Change or revert it first."
            )
        }
    }

    // MARK: - Confirmations (local data deleted)

    static func confirmationTitle(_ drift: DriftModel) -> String {
        switch drift.subject {
        case .item(let item):
            String(localized: "drift.confirm.deleteItem.title", defaultValue: "Delete \(item.name) from your vault?")
        case .environment(let environment):
            String(
                localized: "drift.confirm.deleteEnvironment.title",
                defaultValue: "Delete environment \(environment.name) from your vault?"
            )
        }
    }

    static func confirmationMessage(_ drift: DriftModel) -> String {
        switch drift.subject {
        case .item:
            String(
                localized: "drift.confirm.deleteItem.message",
                defaultValue: "GitHub no longer has it. Its value is removed from FX Vault and cannot be recovered."
            )
        case .environment:
            String(
                localized: "drift.confirm.deleteEnvironment.message",
                defaultValue: "GitHub no longer has it. Its secrets and variables are removed from FX Vault and cannot be recovered."
            )
        }
    }

    static let confirmDelete = String(localized: "drift.confirm.delete", defaultValue: "Delete from Vault")

    // MARK: - Notes

    static func unreadable(_ failure: ImportReadFailureModel) -> String {
        let reason = failure.error.localizedMessage
        let repository = String(localized: "sync.scope.repository", defaultValue: "Repository")
        switch failure.target {
        case .environments:
            return String(
                localized: "drift.unreadable.environments",
                defaultValue: "Environments were not compared. \(reason)"
            )
        case .branchPolicies(let environment):
            return String(
                localized: "drift.unreadable.branchPolicies",
                defaultValue: "Branch rules of \(environment) were not compared. \(reason)"
            )
        case .secrets(let environment):
            return String(
                localized: "drift.unreadable.secrets",
                defaultValue: "Secrets in \(environment ?? repository) were not compared. \(reason)"
            )
        case .variables(let environment):
            return String(
                localized: "drift.unreadable.variables",
                defaultValue: "Variables in \(environment ?? repository) were not compared. \(reason)"
            )
        }
    }

    static func skipped(_ names: [String]) -> String {
        String(
            localized: "drift.skipped",
            defaultValue: "GitHub has names FX Vault cannot store, so they were not compared: \(names.joined(separator: ", "))."
        )
    }

    static func expired(_ count: Int) -> String {
        String(
            localized: "drift.expired",
            defaultValue: "GitHub never confirmed \(count) earlier pushes. They are pending again for the next Sync."
        )
    }

    static func checkedAt(_ date: String) -> String {
        String(localized: "drift.checkedAt", defaultValue: "Checked \(date)")
    }

    static let resolved = String(localized: "drift.notice.resolved", defaultValue: "Saved. The next Sync pushes your choice.")

    static let needsGH = String(
        localized: "drift.needsGH",
        defaultValue: "Checking GitHub needs the GitHub CLI with a logged-in account."
    )

    // MARK: - Banner

    /// "3 changes on GitHub" (§10 Column 3).
    static func bannerTitle(count: Int) -> String {
        count == 1
            ? String(localized: "drift.banner.title.one", defaultValue: "1 change on GitHub")
            : String(localized: "drift.banner.title", defaultValue: "\(count) changes on GitHub")
    }

    static func bannerConflicts(_ count: Int) -> String {
        String(localized: "drift.banner.conflicts", defaultValue: "\(count) also changed in your vault")
    }
}
