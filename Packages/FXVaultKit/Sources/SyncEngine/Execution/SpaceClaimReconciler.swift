import Foundation
import GitHubKit
import os
import VaultCore

/// What launch reconciliation did with unfinished shared space claims.
public struct SpaceClaimReconciliationModel: Sendable, Hashable {
    /// Claims finished with a confirmed `published` marker.
    public var finished = 0
    /// Claims another member's marker replaced (no version recorded for them).
    public var abandoned = 0
    /// Claims left for the next launch (no gh access, a failed listing or write).
    public var unchecked = 0

    public init() {}
}

/// Launch reconciliation of shared space claims (v0.6.0, tasks/todo.md S5).
///
/// A crash between a claim and its confirmed `published` marker, or a marker write that failed,
/// leaves the claim recorded. For each such scope the marker is listed again: when the gate still
/// lets this Mac push (the marker is its own claim, or names its head), the version of what
/// GitHub now holds is recorded (journal reconciliation ran first, so the rows match GitHub) and
/// the `published` marker is written and confirmed; when another member's marker replaced it,
/// the claim ends.
public struct SpaceClaimReconciler: Sendable {
    private let schedulers: SyncSchedulerRegistry
    private let spaces: any SyncSpaceCoordinating

    public init(schedulers: SyncSchedulerRegistry, spaces: any SyncSpaceCoordinating) {
        self.schedulers = schedulers
        self.spaces = spaces
    }

    @discardableResult
    public func reconcile(_ snapshots: [RepoSnapshotModel]) async -> SpaceClaimReconciliationModel {
        var result = SpaceClaimReconciliationModel()
        for snapshot in snapshots {
            let claims: [SyncSharedScopeModel]
            do {
                claims = try spaces.sharedScopes(repositoryID: snapshot.repository.id).filter(\.hasUnfinishedClaim)
            } catch {
                continue
            }
            guard !claims.isEmpty else { continue }
            guard let scheduler = schedulers.scheduler(for: snapshot.repository.accountLogin),
                  let ref = try? GHRepoRef(owner: snapshot.repository.ownerLogin, name: snapshot.repository.name)
            else {
                result.unchecked += claims.count
                continue
            }
            for claim in claims {
                await reconcile(claim, snapshot: snapshot, scheduler: scheduler, ref: ref, into: &result)
            }
        }
        if result != SpaceClaimReconciliationModel() {
            SyncLog.sync.info(
                "space claims: \(result.finished, privacy: .public) finished, \(result.abandoned, privacy: .public) abandoned, \(result.unchecked, privacy: .public) unchecked"
            )
        }
        return result
    }

    private func reconcile(
        _ claim: SyncSharedScopeModel,
        snapshot: RepoSnapshotModel,
        scheduler: GHCommandScheduler,
        ref: GHRepoRef,
        into result: inout SpaceClaimReconciliationModel
    ) async {
        var environment: String?
        if let id = claim.scope.environmentID {
            guard let found = snapshot.environment(id) else {
                result.unchecked += 1
                return
            }
            environment = found.syncedName ?? found.name
        }
        do {
            let listed = try await scheduler.listVariableScope(ref, environment: environment).spaceMarker
            guard try spaces.gate(spaceID: claim.spaceID, markerText: listed).allowsPush else {
                try spaces.abandonClaim(spaceID: claim.spaceID)
                result.abandoned += 1
                return
            }
            let marker = try spaces.publish(spaceID: claim.spaceID, reason: nil, tookOverFrom: nil)
            try await scheduler.setSpaceMarker(marker, repo: ref, environment: environment, isUpdate: listed != nil)
            guard try await scheduler.listVariableScope(ref, environment: environment).spaceMarker == marker else {
                result.unchecked += 1
                return
            }
            try spaces.confirmPublished(spaceID: claim.spaceID)
            result.finished += 1
        } catch {
            result.unchecked += 1
        }
    }
}
