import Foundation
import GitHubKit
import os
import VaultCore

/// Shared scopes (v0.6.0, tasks/todo.md S5 steps 3, 5 and 6).
///
/// - **Claim** before a shared scope's first write: the coordinator records the claim, the
///   `publishing` marker is written and re-read. A definitive write failure ends the claim and
///   fails the scope's changes; a different marker on re-read (another member claimed) ends it
///   and blocks them; an unconfirmed claim (the re-read failed) fails them but stays claimed, so
///   the publish below (or launch reconciliation) puts a `published` marker back.
/// - **Publish** after the repository's steps, for every claimed scope: the coordinator records
///   the version of what GitHub now holds (none when nothing changed), the `published` marker is
///   written and re-read, and only a confirmed marker finishes the claim.
extension SyncExecutor {
    /// Claims the shared scope `step` writes, once per run. Returns the outcome of every change
    /// of the step when the scope cannot be written (nil: go on).
    func claimSharedScope(of step: SyncStepModel, run: inout RepoRun) async throws(SyncError) -> SyncChangeOutcomeModel? {
        guard let spaces, let scopeStep = step.itemScopeStep else { return nil }
        let scope = ConfigScope(environmentID: scopeStep.environmentID)
        if let lost = run.lostSpaces[scope] {
            return lost
        }
        guard let gate = run.plan.spaces.first(where: { $0.scope == scope }),
              !run.claimedSpaces.contains(where: { $0.gate.spaceID == gate.spaceID }),
              let ref = run.ref
        else { return nil }
        let marker = try spaces.claim(spaceID: gate.spaceID)
        let scheduler = run.scheduler
        let environment = scopeStep.environmentName
        let written = await attempt { () async throws(GHError) in
            try await scheduler.setSpaceMarker(marker, repo: ref, environment: environment, isUpdate: gate.hasMarker)
        }
        if case .failure(let error) = written, !error.mayHaveApplied {
            try spaces.abandonClaim(spaceID: gate.spaceID)
            if let reason = SyncStopReason.from(error) { stop(reason) }
            return lose(scope, outcome: .failed(.github(error)), run: &run)
        }
        let listed = await attempt { () async throws(GHError) -> String? in
            try await scheduler.listVariableScope(ref, environment: environment).spaceMarker
        }
        switch listed {
        case .success(let current) where current == marker:
            run.claimedSpaces.append((gate, environment))
            return nil
        case .success(let current):
            try spaces.abandonClaim(spaceID: gate.spaceID)
            let decision = try spaces.gate(spaceID: gate.spaceID, markerText: current)
            let block = SyncSpaceBlockModel(spaceID: gate.spaceID, decision: decision.allowsPush ? .forked : decision)
            SyncLog.sync.info("space claim lost on re-read")
            return lose(scope, outcome: .blocked(.space(block)), run: &run)
        case .failure(let error):
            // The marker may be ours: publish restores a `published` one after the steps.
            run.claimedSpaces.append((gate, environment))
            if let reason = SyncStopReason.from(error) { stop(reason) }
            return lose(scope, outcome: .failed(.github(error)), run: &run)
        }
    }

    /// Records each claimed scope's version and writes its `published` marker.
    func publishClaimedSpaces(_ run: RepoRun) async {
        guard let spaces, let ref = run.ref else { return }
        let scheduler = run.scheduler
        for (gate, environment) in run.claimedSpaces {
            let marker: String
            do {
                marker = try spaces.publish(spaceID: gate.spaceID, reason: spaceReason, tookOverFrom: gate.takenOverFrom)
            } catch {
                warn(.spaceNotPublished(spaceID: gate.spaceID))
                continue
            }
            let written = await attempt { () async throws(GHError) in
                try await scheduler.setSpaceMarker(marker, repo: ref, environment: environment, isUpdate: true)
            }
            let listed = await attempt { () async throws(GHError) -> String? in
                try await scheduler.listVariableScope(ref, environment: environment).spaceMarker
            }
            switch (written, listed) {
            case (_, .success(let current)) where current == marker:
                do {
                    try spaces.confirmPublished(spaceID: gate.spaceID)
                } catch {
                    warn(.spaceNotPublished(spaceID: gate.spaceID))
                }
            case (.success, .success):
                warn(.spaceForked(spaceID: gate.spaceID))
            default:
                warn(.spaceNotPublished(spaceID: gate.spaceID))
            }
        }
    }

    private func lose(_ scope: ConfigScope, outcome: SyncChangeOutcomeModel, run: inout RepoRun) -> SyncChangeOutcomeModel {
        run.lostSpaces[scope] = outcome
        return outcome
    }
}

extension SyncStepModel {
    /// The item step (writes or deletes of one scope), nil for every other step.
    var itemScopeStep: ScopeStepModel? {
        switch self {
        case .writeScope(let step), .deleteItems(let step): step
        default: nil
        }
    }
}
