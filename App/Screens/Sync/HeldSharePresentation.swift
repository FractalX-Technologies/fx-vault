import Foundation
import VaultCore
import VaultData

/// One share file in Sync's From Files review (v0.9.0, P8): who sent it, when, what it holds
/// back, and whether this run includes it. Names only.
struct SyncHeldShareRowModel: Identifiable, Hashable {
    let id: SharePackageID
    let title: String
    let isVerified: Bool
    let meta: String
    let itemCount: Int
    let groups: [SyncHeldShareGroupModel]
    let isIncluded: Bool
}

/// The held rows of one file in one scope or destination: "OWNER/REPO · STAGING", "+ NAME".
struct SyncHeldShareGroupModel: Identifiable, Hashable {
    let id: String
    let title: String
    let names: String
    let note: String?
}

enum HeldSharePresentation {
    /// The review rows of `shares`, in the order the repository returned them (newest import
    /// first).
    static func rows(_ shares: [HeldShareModel], included: Set<SharePackageID>) -> [SyncHeldShareRowModel] {
        let showsRepository = Set(shares.flatMap { $0.repositories.map(\.id) }).count > 1
        return shares.map { share in
            SyncHeldShareRowModel(
                id: share.packageID,
                title: HeldShareCopy.fileTitle(sender: share.senderName),
                isVerified: share.isSenderVerified,
                meta: HeldShareCopy.meta(importedAt: share.importedAt, itemCount: share.itemCount),
                itemCount: share.itemCount,
                groups: groups(share, showsRepository: showsRepository),
                isIncluded: included.contains(share.packageID)
            )
        }
    }

    private static func groups(_ share: HeldShareModel, showsRepository: Bool) -> [SyncHeldShareGroupModel] {
        share.repositories.flatMap { repository in
            let prefix = showsRepository ? "\(repository.repository.fullName) · " : ""
            let scopes = repository.scopes.map { scope in
                SyncHeldShareGroupModel(
                    id: "\(repository.id.uuidString)|\(scope.id)",
                    title: prefix + SyncCopy.scopeLabel(environmentName: scope.environmentName),
                    names: line(scope.items),
                    note: scope.holdsEnvironment ? scope.environmentName.map(HeldShareCopy.createsEnvironment) : nil
                )
            }
            let destinations = repository.destinations.map { destination in
                SyncHeldShareGroupModel(
                    id: "\(repository.id.uuidString)|destination|\(destination.id.uuidString)",
                    title: prefix + destination.destination.copyTargetTitle,
                    names: line(destination.items),
                    note: nil
                )
            }
            return scopes + destinations
        }
    }

    /// "+ NEW_KEY   ~ CHANGED_KEY" (the Sync summary's symbols).
    static func line(_ items: [HeldShareItemModel]) -> String {
        items.map { "\($0.isNew ? "+" : "~") \($0.name)" }.joined(separator: "   ")
    }

    /// `review` as the run would be with `included` files: their held changes back in the
    /// preflight and the credential warnings. Pass the original review and the same set to
    /// `startRun`.
    static func effective(_ review: SyncReviewModel, including included: Set<SharePackageID>) -> SyncReviewModel {
        guard !included.isEmpty else { return review }
        var effective = review
        effective.preflight = review.preflight(including: included)
        effective.credentialWarnings = review.credentialWarnings(including: included)
        return effective
    }

    /// `review` with the sendable held writes of `included` files among the changes, and the
    /// ones that still cannot be sent among the blocked ones, for the summary and the counts.
    /// The run itself takes the original review and `includeHeld`.
    static func effective(_ review: DestinationReviewModel, including included: Set<SharePackageID>) -> DestinationReviewModel {
        guard !included.isEmpty else { return review }
        let sections = review.sections.map { section -> DestinationReviewSectionModel in
            let included = section.held.filter { included.contains($0.packageID) }
            guard !included.isEmpty else { return section }
            let writes = included.filter { $0.reason == nil }.map(\.change)
            let blocked = included.compactMap { held in
                held.reason.map { DestinationBlockedChangeModel(change: held.change, reason: $0) }
            }
            return DestinationReviewSectionModel(
                destination: section.destination,
                changes: section.writes + writes + section.deletions,
                blocked: section.blocked + blocked,
                held: section.held
            )
        }
        return DestinationReviewModel(repositoryID: review.repositoryID, sections: sections)
    }

    /// True when the destination review has anything for this Sync: pending changes or held
    /// rows (which the From Files review can include).
    static func hasContent(_ review: DestinationReviewModel) -> Bool {
        !review.isEmpty || review.sections.contains { !$0.held.isEmpty }
    }
}

extension FeatureDependencies {
    /// Rows held by share files (v0.9.0): the From Files review and releasing holds.
    var shareHolds: ShareHoldRepository {
        ShareHoldRepository(session: session)
    }
}

/// The sender names of share files, for the Held chip's tooltip. Reads each file's name once.
@MainActor
final class HeldSenderNames {
    private let holds: () -> ShareHoldRepository
    private var names: [SharePackageID: String?] = [:]

    init(holds: @escaping () -> ShareHoldRepository) {
        self.holds = holds
    }

    /// The sender of `packageID`, nil when the file named none or cannot be read.
    func name(of packageID: SharePackageID) -> String? {
        if let known = names[packageID] {
            return known
        }
        let shares = (try? holds().heldShares()) ?? []
        for share in shares {
            names[share.packageID] = share.senderName
        }
        let name = names[packageID] ?? nil
        names[packageID] = .some(name)
        return name
    }
}
