import Foundation
import os
@testable import SyncEngine
import VaultCore

/// A ``SyncSpaceCoordinating`` that records calls. Its own markers (`claim-N`, `published-N`)
/// pass the gate; any other marker gets ``State/foreignDecision``.
final class FakeSpaceCoordinator: SyncSpaceCoordinating, Sendable {
    struct Publish: Hashable {
        let spaceID: SpaceID
        let reason: String?
        let tookOverFrom: String?
    }

    struct State {
        var shared: [RepoID: [SyncSharedScopeModel]] = [:]
        var foreignDecision: SpaceGateDecision = .clear
        var ownMarkers: Set<String> = []
        var counter = 0
        var claims: [SpaceID] = []
        var published: [Publish] = []
        var confirmed: [SpaceID] = []
        var abandoned: [SpaceID] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(shared: [RepoID: [SyncSharedScopeModel]], foreignDecision: SpaceGateDecision = .clear) {
        state = OSAllocatedUnfairLock(initialState: State(shared: shared, foreignDecision: foreignDecision))
    }

    var snapshot: State {
        state.withLock { $0 }
    }

    func markOwn(_ marker: String) {
        state.withLock { _ = $0.ownMarkers.insert(marker) }
    }

    func sharedScopes(repositoryID: RepoID) throws(SyncError) -> [SyncSharedScopeModel] {
        state.withLock { $0.shared[repositoryID] ?? [] }
    }

    func gate(spaceID: SpaceID, markerText: String?) throws(SyncError) -> SpaceGateDecision {
        state.withLock { state in
            guard let markerText, !state.ownMarkers.contains(markerText) else { return .clear }
            return state.foreignDecision
        }
    }

    func claim(spaceID: SpaceID) throws(SyncError) -> String {
        state.withLock { state in
            state.counter += 1
            state.claims.append(spaceID)
            let marker = "claim-\(state.counter)"
            state.ownMarkers.insert(marker)
            return marker
        }
    }

    func publish(spaceID: SpaceID, reason: String?, tookOverFrom: String?) throws(SyncError) -> String {
        state.withLock { state in
            state.published.append(Publish(spaceID: spaceID, reason: reason, tookOverFrom: tookOverFrom))
            let marker = "published-\(state.counter)"
            state.ownMarkers.insert(marker)
            return marker
        }
    }

    func confirmPublished(spaceID: SpaceID) throws(SyncError) {
        state.withLock { $0.confirmed.append(spaceID) }
    }

    func abandonClaim(spaceID: SpaceID) throws(SyncError) {
        state.withLock { $0.abandoned.append(spaceID) }
    }
}
