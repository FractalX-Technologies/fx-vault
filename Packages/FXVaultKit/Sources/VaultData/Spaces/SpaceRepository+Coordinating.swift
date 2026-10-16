import Foundation
import os
import SharingKit
import SyncEngine
import VaultCore
import VaultStore

/// The gate, the claim and the publish (S5) for Sync, genesis and member changes.
extension SpaceRepository {
    /// The shared scopes of a repository.
    func sharedScopeModels(_ repositoryID: RepoID) throws(SpaceRepositoryError) -> [SyncSharedScopeModel] {
        try perform {
            try session.database.read { tx in
                try store.fetchSpaces(repositoryID: repositoryID, in: tx).map { record in
                    SyncSharedScopeModel(spaceID: record.id, scope: record.scope, hasUnfinishedClaim: record.claimedVersion != nil)
                }
            }
        }
    }

    /// GitHub's marker against this Mac's verified head (no keys needed).
    func decideGate(_ spaceID: SpaceID, markerText: String?) throws(SpaceRepositoryError) -> SpaceGateDecision {
        let now = clock.now
        return try perform {
            try session.database.read { tx in
                let space = try load(spaceID, in: tx)
                guard let identity = try TeamStore(database: session.database).fetchIdentity(in: tx),
                      let device = TeamDeviceID(hex: identity.deviceID)
                else { return .notAMember }
                return SpaceGate.decide(markerText: markerText, state: space.state, device: device, now: now)
            }
        }
    }

    /// Records the claim of head + 1 and returns its signed `publishing` marker.
    func claimMarker(_ spaceID: SpaceID) throws(SpaceRepositoryError) -> String {
        let device = try teamCall { try team.deviceKeys() }
        let now = clock.now
        return try perform {
            try session.database.write { tx in
                let space = try load(spaceID, in: tx)
                guard space.state.isMember(device.deviceID) else { throw SpaceRepositoryError.notAMember }
                let next = space.state.headVersion + 1
                var record = space.record
                record.claimedVersion = Int64(next)
                record.updatedAt = now
                try store.saveSpace(record, in: tx)
                return try SpaceMarkerModel.make(
                    spaceID: spaceID,
                    version: next,
                    state: .publishing,
                    head: space.state.headHash,
                    login: Self.login(of: device.deviceID, in: space.state),
                    author: device,
                    at: now
                ).encoded()
            }
        }
    }

    /// Records a version of what GitHub now holds when it differs from the last content version,
    /// and returns the signed `published` marker of the head. The claim stays recorded until the
    /// marker is confirmed (``clearClaim(_:)``).
    func publishMarker(_ spaceID: SpaceID, reason: String?, tookOverFrom: String?) throws(SpaceRepositoryError) -> String {
        let device = try teamCall { try team.deviceKeys() }
        let now = clock.now
        let marker: String = try perform {
            try session.write { keys, tx in
                let space = try load(spaceID, in: tx)
                guard space.state.isMember(device.deviceID) else { throw SpaceRepositoryError.notAMember }
                let keychain = try keychain(of: space, keys: keys, in: tx)
                let previous = try Self.latestContent(of: space, keychain: keychain)
                defer { previous?.wipe() }
                let rows = try ConfigStore(database: session.database)
                    .fetchItemRecords(repositoryID: space.record.repositoryID, scope: space.record.scope, in: tx)
                let snapshot = try SpaceSnapshotBuilder.snapshot(
                    of: rows,
                    previous: previous,
                    reason: Self.reason(reason, tookOverFrom: tookOverFrom),
                    keys: keys
                )
                defer { snapshot.wipe() }
                var head = (version: space.state.headVersion, hash: space.state.headHash)
                if previous.map({ !SpaceSnapshotBuilder.sameItems(snapshot, $0) }) ?? true {
                    let version = try SpaceVersionBuilder.publish(
                        state: space.state,
                        keychain: keychain,
                        snapshot: snapshot,
                        author: device,
                        at: now
                    )
                    try append(version, to: space.record, in: tx)
                    head = (version.header.version, version.hash)
                }
                return try SpaceMarkerModel.make(
                    spaceID: spaceID,
                    version: head.version,
                    state: .published,
                    head: head.hash,
                    login: Self.login(of: device.deviceID, in: space.state),
                    author: device,
                    at: now
                ).encoded()
            }
        }
        Self.log.info("Published a shared space version")
        return marker
    }

    /// Ends the claim: its `published` marker is confirmed, or it was lost.
    func clearClaim(_ spaceID: SpaceID) throws(SpaceRepositoryError) {
        let now = clock.now
        try perform {
            try session.database.write { tx in
                guard var record = try store.fetchSpace(id: spaceID, in: tx) else { throw SpaceRepositoryError.spaceNotFound }
                record.claimedVersion = nil
                record.updatedAt = now
                try store.saveSpace(record, in: tx)
            }
        }
    }

    /// The snapshot of the last genesis or publish version. The caller wipes it.
    static func latestContent(of space: LoadedSpace, keychain: SpaceKeychain) throws -> SpaceSnapshotModel? {
        guard let version = space.versions.last(where: { $0.header.kind != .members }) else { return nil }
        return try SpaceVersionBuilder.snapshot(of: version, keychain: keychain)
    }

    static func login(of device: TeamDeviceID, in state: SpaceStateModel) -> String {
        state.members.first { $0.deviceID == device }?.login ?? ""
    }

    /// The version's note: the user's reason, after the takeover (Q3) when there was one.
    static func reason(_ reason: String?, tookOverFrom login: String?) -> String {
        let typed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let login else { return typed }
        let takeover = "Took over the unfinished publish of \(login)."
        return typed.isEmpty ? takeover : "\(takeover) \(typed)"
    }
}

extension SpaceRepository: SyncSpaceCoordinating {
    public func sharedScopes(repositoryID: RepoID) throws(SyncError) -> [SyncSharedScopeModel] {
        try syncCall { try sharedScopeModels(repositoryID) }
    }

    public func gate(spaceID: SpaceID, markerText: String?) throws(SyncError) -> SpaceGateDecision {
        try syncCall { try decideGate(spaceID, markerText: markerText) }
    }

    public func claim(spaceID: SpaceID) throws(SyncError) -> String {
        try syncCall { try claimMarker(spaceID) }
    }

    public func publish(spaceID: SpaceID, reason: String?, tookOverFrom: String?) throws(SyncError) -> String {
        try syncCall { try publishMarker(spaceID, reason: reason, tookOverFrom: tookOverFrom) }
    }

    public func confirmPublished(spaceID: SpaceID) throws(SyncError) {
        try syncCall { try clearClaim(spaceID) }
    }

    public func abandonClaim(spaceID: SpaceID) throws(SyncError) {
        try syncCall { try clearClaim(spaceID) }
        Self.log.info("A shared space claim was lost to another member")
    }

    private func syncCall<Result>(_ body: () throws -> Result) throws(SyncError) -> Result {
        do {
            return try body()
        } catch SpaceRepositoryError.vault(.locked) {
            throw .locked
        } catch SpaceRepositoryError.github(let error) {
            throw .github(error)
        } catch {
            throw .persistenceFailed
        }
    }
}
