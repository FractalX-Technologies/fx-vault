import Foundation
import VaultCore

/// The phrases of the Sync run, its deletion check and its finish (boards Sync-Progress,
/// Sync-Delete, Sync-Done). Names and counts only.
extension SyncCopy {
    /// The footer of what New Repository and New Environment stage (boards NewRepo, NewEnvironment).
    static var createdAtNextSync: String {
        String(localized: "sync.createdAtNextSync", defaultValue: "Created on GitHub at the next Sync.")
    }

    // MARK: - Run (board Sync-Progress)

    static var progressTitle: String {
        String(localized: "sync.progress.title", defaultValue: "Syncing")
    }

    static var progressSubtitle: String {
        String(localized: "sync.progress.subtitle", defaultValue: "Keep FX Vault open until it finishes")
    }

    /// "Writing 5 of 8 · FX Vault writes 60 a minute · Locking stops after the current write."
    static func progressLine(_ progress: SyncRunProgressModel, phase: String?) -> String {
        if progress.isCancelling {
            return String(
                localized: "sync.progress.cancelling",
                defaultValue: "Stopping after the current GitHub call…"
            )
        }
        let step = phase ?? String(
            localized: "sync.progress.writingCount",
            defaultValue: "Writing \(progress.completed) of \(progress.total)"
        )
        let pace = String(
            localized: "sync.progress.pace",
            defaultValue: "FX Vault writes \(Limits.writesPerMinute) a minute"
        )
        let lock = String(localized: "sync.progress.lock", defaultValue: "Locking stops after the current write.")
        return [step, pace, lock].joined(separator: " · ")
    }

    static var cancelAfterCurrent: String {
        String(localized: "sync.button.cancelAfterCurrent", defaultValue: "Cancel After Current")
    }

    /// The last card of the run: the deletions, which run after the writes.
    static var deletionsCardTitle: String {
        String(localized: "sync.progress.deletions", defaultValue: "Deletions")
    }

    static var deletionsCardKind: String {
        String(localized: "sync.progress.deletions.kind", defaultValue: "after the other writes")
    }

    /// "blocked · Value missing locally": a change of the run that will not be written.
    static func blockedDetail(_ reason: String) -> String {
        let trimmed = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        return String(localized: "sync.progress.blocked", defaultValue: "blocked · \(trimmed)")
    }

    // MARK: - Deletions (board Sync-Delete)

    /// "Delete 1 secret?", "Delete 3 variables?", "Delete 4 items?".
    static func deletionTitle(count: Int, kind: ConfigKind?) -> String {
        // Automatic grammar agreement: "Delete 1 secret?", "Delete 2 secrets?".
        let text: AttributedString = switch kind {
        case .secret:
            AttributedString(localized: "sync.deletions.title.secrets", defaultValue: "Delete ^[\(count) secret](inflect: true)?")
        case .variable:
            AttributedString(localized: "sync.deletions.title.variables", defaultValue: "Delete ^[\(count) variable](inflect: true)?")
        case nil:
            AttributedString(localized: "sync.deletions.title.items", defaultValue: "Delete ^[\(count) item](inflect: true)?")
        }
        return String(inflected: text)
    }

    static var deletionSubtitle: String {
        String(
            localized: "sync.deletions.subtitle",
            defaultValue: "Confirm before Sync starts. Deletions run after the other writes."
        )
    }

    /// The deletion check's button: "Delete 2".
    static func deleteButtonTitle(count: Int) -> String {
        String(localized: "sync.button.deleteCount", defaultValue: "Delete \(count)")
    }

    // MARK: - Done (board Sync-Done)

    /// "Synced 8 changes".
    static func doneTitle(count: Int) -> String {
        // Automatic grammar agreement: "Synced 1 change", "Synced 8 changes".
        String(inflected: AttributedString(
            localized: "sync.done.title",
            defaultValue: "Synced ^[\(count) change](inflect: true)"
        ))
    }

    /// "in example-org, api-service › production and kv-example-prod".
    static func donePlaces(_ places: [String]) -> String {
        String(localized: "sync.done.places", defaultValue: "in \(places.formatted(.list(type: .and)))")
    }

    /// One change that stays pending: "Add secret DOCKER_PASSWORD in production · Value missing locally."
    static func donePending(_ issue: SyncIssueModel) -> String {
        "\(issue.title) · \(issue.reason)"
    }

    /// "and 3 more stay pending".
    static func donePendingMore(_ count: Int) -> String {
        String(localized: "sync.done.pendingMore", defaultValue: "and \(count) more stay pending")
    }
}
