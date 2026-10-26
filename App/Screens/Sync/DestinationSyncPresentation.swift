import DestinationKit
import Foundation
import VaultCore
import VaultData

/// The destination part of the Sync sheet (v0.8.0, tasks/todo.md R5): each destination's changes
/// as one more "scope" of its repository in the summary, its blocked changes with their fix, its
/// deletions in the deletion review, and its outcomes in the result. Names only.
enum DestinationSyncPresentation {
    // MARK: Summary

    /// `repositories` with each repository's destination sections appended (a repository with
    /// destination changes only gets a row of its own, and so do the Key Vaults of their own).
    static func merge(
        _ repositories: [SyncSummaryRepoModel],
        with reviews: [DestinationReviewModel],
        repository: (RepoID) -> RepoModel?
    ) -> [SyncSummaryRepoModel] {
        var merged = repositories
        for review in reviews where !review.isEmpty {
            let scopes = review.sections.filter { !$0.changes.isEmpty }.map(scope)
            let blocked = review.sections.flatMap { section in section.blocked.map { issue($0, destination: section.destination) } }
            if let index = merged.firstIndex(where: { $0.id == SyncGroupID(repositoryID: review.repositoryID) }) {
                let current = merged[index]
                merged[index] = SyncSummaryRepoModel(
                    id: current.id,
                    fullName: current.fullName,
                    place: current.place,
                    newRepository: current.newRepository,
                    scopes: current.scopes + scopes,
                    blocked: current.blocked + blocked,
                    dependents: current.dependents,
                    remoteChanged: current.remoteChanged,
                    notes: current.notes,
                    pendingCount: current.pendingCount + review.executableCount
                )
            } else if let section = review.sections.first {
                let model = review.repositoryID.flatMap(repository)
                merged.append(SyncSummaryRepoModel(
                    id: SyncGroupID(repositoryID: review.repositoryID),
                    fullName: review.repositoryID == nil ? MainCopy.azureSection : model?.fullName ?? "",
                    // The Key Vaults of their own have no place above their vaults.
                    place: review.repositoryID == nil
                        ? place(section.destination)
                        : SyncPresentationBuilder.repositoryPlace(name: model?.name ?? ""),
                    scopes: scopes,
                    blocked: blocked,
                    pendingCount: review.executableCount
                ))
            }
        }
        return merged
    }

    /// "kv-example-prod · Key Vault".
    static func place(_ destination: DestinationModel) -> SyncPlaceModel {
        SyncPlaceModel(
            id: "destination|\(destination.id.uuidString)",
            systemImage: destination.provider.symbolName,
            name: destination.title,
            kind: destination.provider.shortTitle
        )
    }

    private static func scope(_ section: DestinationReviewSectionModel) -> SyncSummaryScopeModel {
        SyncSummaryScopeModel(
            place: place(section.destination),
            sentence: DestinationSyncCopy.sentence(writes: section.writes.count, deletions: section.deletions.count),
            lines: section.changes.map { lineModel($0, provider: section.destination.provider) }
        )
    }

    /// "~ STRIPE_SECRET_KEY as STRIPE-SECRET-KEY", "− LEGACY_API_KEY".
    static func line(_ change: DestinationChangeModel) -> String {
        let remote = change.remoteName == change.name ? "" : " " + DestinationSyncCopy.asRemote(change.remoteName)
        return "\(symbol(change).rawValue) \(change.name)\(remote)"
    }

    /// The card's line: `~ STRIPE_SECRET_KEY  secret · as STRIPE-SECRET-KEY`.
    private static func lineModel(_ change: DestinationChangeModel, provider: DestinationProvider) -> SyncChangeLineModel {
        SyncChangeLineModel(
            symbol: symbol(change),
            name: change.name,
            detail: SyncCopy.lineDetail(
                SyncCopy.kindTitle(change.kind),
                change.remoteName == change.name ? nil : DestinationSyncCopy.asRemote(change.remoteName),
                change.operation == .delete ? DestinationSyncCopy.deletedIn(provider) : nil
            ),
            text: line(change),
            kind: change.kind
        )
    }

    private static func symbol(_ change: DestinationChangeModel) -> SyncChangeLineModel.Symbol {
        switch change.operation {
        case .add: .added
        case .update: .modified
        case .delete: .deleted
        }
    }

    private static func issue(_ blocked: DestinationBlockedChangeModel, destination: DestinationModel) -> SyncIssueModel {
        SyncIssueModel(
            id: "destination|\(blocked.id)",
            title: "\(blocked.change.name) · \(destination.copyTargetTitle)",
            reason: DestinationSyncCopy.reason(blocked.reason, provider: destination.provider),
            fix: fix(for: blocked.reason, change: blocked.change),
            place: place(destination),
            name: blocked.change.name
        )
    }

    static func fix(for reason: DestinationBlockReason, change: DestinationChangeModel) -> SyncFixActionModel? {
        switch reason {
        case .valueMissing:
            .fillValue(ItemEditorContext(destinationID: change.destinationID, mode: .fill(change.itemID)))
        case .invalidName:
            .editItem(ItemEditorContext(destinationID: change.destinationID, mode: .edit(change.itemID)))
        case .remoteChanged, .existsRemotely:
            .openDestination(change.destinationID)
        case .listingFailed(let error):
            fix(for: error, destinationID: change.destinationID)
        }
    }

    static func fix(for error: DestinationError, destinationID: DestinationID) -> SyncFixActionModel? {
        switch error {
        case .azNotSignedIn: .runInTerminal(command: DestinationSyncCopy.azLoginCommand)
        case .azNotInstalled: .runInTerminal(command: DestinationSyncCopy.azInstallCommand)
        case .tokenMissing, .unauthorized, .forbidden, .notFound: .openDestination(destinationID)
        default: nil
        }
    }

    // MARK: Deletions

    /// `rows` with each repository's destination deletions appended.
    static func mergeDeletions(
        _ rows: [SyncDeletionRepoModel],
        with reviews: [DestinationReviewModel],
        fullName: (RepoID?) -> String
    ) -> [SyncDeletionRepoModel] {
        var merged = rows
        for review in reviews {
            let items = review.sections.flatMap { section in
                section.deletions.map { change in
                    SyncIssueModel(
                        id: "destination|\(change.id)",
                        title: DestinationSyncCopy.deletionTitle(name: change.name, destination: section.destination.copyTargetTitle),
                        reason: "",
                        place: place(section.destination),
                        name: change.name
                    )
                }
            }
            guard !items.isEmpty else { continue }
            if let index = merged.firstIndex(where: { $0.id == SyncGroupID(repositoryID: review.repositoryID) }) {
                let current = merged[index]
                merged[index] = SyncDeletionRepoModel(
                    id: current.id,
                    fullName: current.fullName,
                    items: current.items + items,
                    environments: current.environments
                )
            } else {
                merged.append(SyncDeletionRepoModel(id: SyncGroupID(repositoryID: review.repositoryID), fullName: fullName(review.repositoryID), items: items, environments: []))
            }
        }
        return merged
    }

    // MARK: Result

    /// The destination rows of each result section.
    static func resultRows(
        _ results: [DestinationRunResultModel],
        reviews: [DestinationReviewModel]
    ) -> [SyncResultSectionModel.Kind: [SyncIssueModel]] {
        var changes: [String: (DestinationChangeModel, DestinationModel)] = [:]
        for review in reviews {
            for section in review.sections {
                for change in section.changes {
                    changes[change.id] = (change, section.destination)
                }
            }
        }
        var rows: [SyncResultSectionModel.Kind: [SyncIssueModel]] = [:]
        for result in results {
            for (id, outcome) in result.outcomes.sorted(by: { $0.key < $1.key }) {
                guard let (change, destination) = changes[id] else { continue }
                let title = "\(line(change)) · \(destination.copyTargetTitle)"
                let kind: SyncResultSectionModel.Kind
                let reason: String
                var fix: SyncFixActionModel?
                switch outcome {
                case .done:
                    kind = .succeeded
                    reason = DestinationSyncCopy.confirmed
                case .unconfirmed:
                    kind = .succeeded
                    reason = DestinationSyncCopy.unconfirmed
                case .failed(let error):
                    kind = .failed
                    reason = error.localizedMessage(provider: destination.provider)
                    fix = Self.fix(for: error, destinationID: destination.id)
                case .blocked(let blocked):
                    kind = .blocked
                    reason = DestinationSyncCopy.reason(blocked, provider: destination.provider)
                    fix = Self.fix(for: blocked, change: change)
                case .skipped:
                    kind = .skipped
                    reason = DestinationSyncCopy.skipped
                }
                rows[kind, default: []].append(SyncIssueModel(id: "destination|\(id)", title: title, reason: reason, fix: fix))
            }
        }
        return rows
    }
}
