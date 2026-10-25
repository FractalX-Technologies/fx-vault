import Foundation
import GitHubKit
import VaultCore
import VaultData

/// The organization part of the Sync sheet (1.0, tasks/todo.md B6b3b): each organization with
/// changes is one more group of the summary, the deletion review and the result. Names only.
enum OrgSyncPresentation {
    // MARK: Summary

    static func summary(_ reviews: [OrgReviewModel]) -> [SyncSummaryRepoModel] {
        reviews.filter { !$0.isEmpty }.map { review in
            let scopes = review.changes.isEmpty ? [] : [SyncSummaryScopeModel(
                id: "organization|\(review.organizationID.uuidString)",
                title: OrgSyncCopy.scopeTitle,
                sentence: DestinationSyncCopy.sentence(writes: review.writes.count, deletions: review.deletions.count),
                details: review.changes.map(line)
            )]
            return SyncSummaryRepoModel(
                id: .organization(review.organizationID),
                fullName: review.login,
                newRepository: nil,
                scopes: scopes,
                blocked: review.blocked.map { blocked in
                    SyncIssueModel(
                        id: "organization|\(blocked.id.uuidString)",
                        title: blocked.change.name,
                        reason: OrgSyncCopy.reason(blocked.reason),
                        fix: fix(for: blocked.reason, change: blocked.change, organizationID: review.organizationID)
                    )
                },
                dependentCount: 0,
                remoteChanged: [],
                notes: [],
                pendingCount: review.changes.count
            )
        }
    }

    /// "+ NPM_TOKEN", "↑ STRIPE_KEY", "− LEGACY_TOKEN".
    static func line(_ change: OrgChangeModel) -> String {
        let symbol = switch change.operation {
        case .add: "+"
        case .update: "↑"
        case .delete: "−"
        }
        return "\(symbol) \(change.name)"
    }

    static func fix(for reason: OrgBlockReason, change: OrgChangeModel, organizationID: OrganizationID) -> SyncFixActionModel? {
        switch reason {
        case .valueMissing, .noRepositories:
            .editOrganizationItem(OrgItemEditorContext(organizationID: organizationID, mode: .edit(change.itemID), repositoryCandidates: []))
        case .listingFailed(let error):
            SyncPresentationBuilder.fix(for: error, repository: nil)
        case .existsRemotely, .remoteChanged:
            nil
        }
    }

    // MARK: Deletions

    static func deletions(_ reviews: [OrgReviewModel]) -> [SyncDeletionRepoModel] {
        reviews.compactMap { review in
            guard !review.deletions.isEmpty else { return nil }
            return SyncDeletionRepoModel(
                id: .organization(review.organizationID),
                fullName: review.login,
                items: review.deletions.map { change in
                    SyncIssueModel(
                        id: "organization|\(change.id.uuidString)",
                        title: DestinationSyncCopy.deletionTitle(name: change.name, destination: review.login),
                        reason: ""
                    )
                },
                environments: []
            )
        }
    }

    // MARK: Result

    static func resultRows(
        _ results: [OrganizationID: OrgRunResultModel],
        reviews: [OrgReviewModel]
    ) -> [SyncResultSectionModel.Kind: [SyncIssueModel]] {
        var rows: [SyncResultSectionModel.Kind: [SyncIssueModel]] = [:]
        for review in reviews {
            guard let result = results[review.organizationID] else { continue }
            for change in review.changes {
                guard let outcome = result.outcomes[change.itemID] else { continue }
                let kind: SyncResultSectionModel.Kind
                let reason: String
                var fix: SyncFixActionModel?
                switch outcome {
                case .done:
                    kind = .succeeded
                    reason = OrgSyncCopy.confirmed
                case .unconfirmed:
                    kind = .succeeded
                    reason = OrgSyncCopy.unconfirmed
                case .failed(let error):
                    kind = .failed
                    reason = error.localizedMessage
                    fix = SyncPresentationBuilder.fix(for: error, repository: nil)
                case .blocked(let blocked):
                    kind = .blocked
                    reason = OrgSyncCopy.reason(blocked)
                    fix = Self.fix(for: blocked, change: change, organizationID: review.organizationID)
                case .skipped:
                    kind = .skipped
                    reason = DestinationSyncCopy.skipped
                }
                rows[kind, default: []].append(SyncIssueModel(
                    id: "organization|\(change.id.uuidString)",
                    title: "\(line(change)) · \(review.login)",
                    reason: reason,
                    fix: fix
                ))
            }
        }
        return rows
    }
}

/// The text of organization changes in the Sync sheet (1.0). Names only.
enum OrgSyncCopy {
    static var scopeTitle: String {
        String(localized: "sync.organization.scope", defaultValue: "Organization secrets and variables")
    }

    static func reason(_ reason: OrgBlockReason) -> String {
        switch reason {
        case .existsRemotely:
            String(
                localized: "sync.organization.blocked.exists",
                defaultValue: "The organization already has this name on GitHub. Delete yours or pick another name."
            )
        case .remoteChanged:
            String(
                localized: "sync.organization.blocked.remoteChanged",
                defaultValue: "It changed on GitHub since FX Vault last read it, so it is not sent."
            )
        case .valueMissing:
            String(
                localized: "sync.organization.blocked.valueMissing",
                defaultValue: "GitHub needs the secret's value to change it, and FX Vault does not have it. Fill it first."
            )
        case .noRepositories:
            String(
                localized: "sync.organization.blocked.noRepositories",
                defaultValue: "Selected access needs at least one repository. Pick repositories or another access."
            )
        case .listingFailed(let error):
            String(
                localized: "sync.organization.blocked.listing",
                defaultValue: "The organization could not be listed, so nothing is sent there: \(error.localizedMessage)"
            )
        }
    }

    static var confirmed: String {
        String(localized: "sync.organization.confirmed", defaultValue: "Confirmed on GitHub")
    }

    static var unconfirmed: String {
        String(
            localized: "sync.organization.unconfirmed",
            defaultValue: "Sent, but GitHub did not list it yet. The next Sync sends it again."
        )
    }
}
