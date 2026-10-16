import Foundation
import os
import SharingKit
import VaultCore
import VaultCrypto
import VaultStore

/// Versions between teammates (S6, S8): what this Mac offers a peer and what it accepts.
///
/// A peer only gets versions of spaces it is a member of at this Mac's head. A received version
/// is accepted from any paired teammate (relaying is safe: every version is signed by a member
/// and chained by hash), verified against the stored log, stored and applied to the scope's rows
/// in one transaction. A space this Mac is publishing in (an open claim) is not advanced until
/// the claim ends.
extension SpaceRepository {
    /// The head of every space `peer` is a member of.
    public func heads(sharedWith peer: TeamDeviceID) throws(SpaceRepositoryError) -> [SpaceHeadModel] {
        try perform {
            try session.database.read { tx in
                try store.fetchSpaces(in: tx).compactMap { record in
                    let space = try load(record.id, in: tx)
                    guard space.state.isMember(peer) else { return nil }
                    return SpaceHeadModel(spaceID: record.id, version: space.state.headVersion, hash: space.state.headHash)
                }
            }
        }
    }

    /// Version `number` of a space `peer` is a member of, in wire form; nil otherwise.
    public func version(_ number: UInt64, of spaceID: SpaceID, for peer: TeamDeviceID) throws(SpaceRepositoryError) -> Data? {
        try perform {
            try session.database.read { tx in
                guard try store.fetchSpace(id: spaceID, in: tx) != nil else { return nil }
                let space = try load(spaceID, in: tx)
                guard space.state.isMember(peer) else { return nil }
                return space.versions.first { $0.header.version == number }?.encoded()
            }
        }
    }

    /// Verifies, stores and applies versions a teammate sent, in order (S8). For a space this Mac
    /// does not have, `versions` must be its whole log from version 1: this device must be a
    /// member at its head (a member added later is not in version 1). Only the newest content
    /// version is applied to the rows.
    public func receive(_ versions: [Data], spaceID: SpaceID, from peer: TeamDeviceID) throws(SpaceRepositoryError) -> SpaceReceiveOutcomeModel {
        let decoded = try Self.decode(versions, spaceID: spaceID)
        guard !decoded.isEmpty else { return .alreadyHave }
        let device = try teamCall { try team.deviceKeys() }
        let now = clock.now
        let outcome: SpaceReceiveOutcomeModel = try perform {
            try session.write { keys, tx in
                if try store.fetchSpace(id: spaceID, in: tx) != nil {
                    return try receiveNext(decoded, device: device, keys: keys, in: tx)
                }
                return try receiveNew(decoded, device: device, now: now, keys: keys, in: tx)
            }
        }
        if case .stored(_, let number, let applied) = outcome {
            Self.log.info(
                "Stored shared space versions from a teammate up to v\(number, privacy: .public): \(applied.updated, privacy: .public) updated, \(applied.conflictNames.count, privacy: .public) kept as drafts"
            )
        }
        return outcome
    }

    private static func decode(_ versions: [Data], spaceID: SpaceID) throws(SpaceRepositoryError) -> [SpaceVersionModel] {
        var decoded: [SpaceVersionModel] = []
        for data in versions {
            guard data.count <= SpaceProtocol.maxVersionBytes else { throw .log(.malformed) }
            let version: SpaceVersionModel
            do {
                version = try SpaceVersionModel.decode(data)
            } catch {
                throw .log(.malformed)
            }
            guard version.header.spaceID == spaceID else { throw .log(.wrongSpace) }
            decoded.append(version)
        }
        return decoded
    }

    /// Versions of a space this Mac has: each must follow the head (or be one it already has).
    private func receiveNext(
        _ versions: [SpaceVersionModel],
        device: TeamDeviceKeys,
        keys: borrowing UnlockedKeys,
        in tx: StoreTransaction
    ) throws -> SpaceReceiveOutcomeModel {
        let space = try load(versions[0].header.spaceID, in: tx)
        var state = space.state
        var added: [SpaceVersionModel] = []
        for version in versions {
            let number = version.header.version
            if number <= state.headVersion {
                let known = (space.versions + added).first { $0.header.version == number }
                guard known?.hash == version.hash else { return .forked }
                continue
            }
            guard number == state.headVersion + 1 else { return .gap }
            state = try SpaceLog.apply(version, to: state)
            added.append(version)
        }
        guard !added.isEmpty else { return .alreadyHave }
        guard space.record.claimedVersion == nil else { return .busy }
        var keychain = try keychain(of: space, keys: keys, in: tx)
        var record = space.record
        for version in added {
            try keychain.add(version, device: device)
            try append(version, to: record, in: tx)
            record.headVersion = Int64(version.header.version)
            record.headHash = version.hash
            record.epoch = Int64(version.header.epoch)
        }
        try saveKeys(keychain, spaceID: record.id, keys: keys, in: tx)
        let applied = try applyNewestContent(of: added, state: state, device: device, keychain: keychain, record: record, keys: keys, in: tx)
        return .stored(spaceID: record.id, version: record.headVersion, applied: applied)
    }

    /// A whole log of a space this Mac does not have: bound to a repository (and environment)
    /// of this vault, with this device a member at its head.
    private func receiveNew(
        _ versions: [SpaceVersionModel],
        device: TeamDeviceKeys,
        now: Date,
        keys: borrowing UnlockedKeys,
        in tx: StoreTransaction
    ) throws -> SpaceReceiveOutcomeModel {
        guard versions[0].header.version == 1 else { return .gap }
        let spaceID = versions[0].header.spaceID
        let state = try SpaceLog.verify(versions, spaceID: spaceID)
        guard state.isMember(device.deviceID) else { return .notAMember }
        guard let scope = try localScope(of: state.binding, in: tx) else { return .repositoryMissing }
        guard try store.fetchSpace(repositoryID: scope.repositoryID, scope: scope.scope, in: tx) == nil else {
            return .scopeAlreadyShared
        }
        let keychain = try SpaceKeychain(versions: versions, device: device)
        let record = SpaceRecord(
            id: spaceID,
            repositoryID: scope.repositoryID,
            scope: scope.scope,
            headVersion: Int64(state.headVersion),
            headHash: state.headHash,
            epoch: Int64(state.epoch),
            createdAt: now,
            updatedAt: now
        )
        try store.saveSpace(record, in: tx)
        for version in versions {
            try store.appendVersion(Self.record(of: version), in: tx)
        }
        try saveKeys(keychain, spaceID: spaceID, keys: keys, in: tx)
        let applied = try applyNewestContent(of: versions, state: state, device: device, keychain: keychain, record: record, keys: keys, in: tx)
        return .stored(spaceID: spaceID, version: record.headVersion, applied: applied)
    }

    /// Applies the newest genesis or publish version of `versions` while this device is a member.
    private func applyNewestContent(
        of versions: [SpaceVersionModel],
        state: SpaceStateModel,
        device: TeamDeviceKeys,
        keychain: SpaceKeychain,
        record: SpaceRecord,
        keys: borrowing UnlockedKeys,
        in tx: StoreTransaction
    ) throws -> SpaceApplyResultModel {
        guard state.isMember(device.deviceID),
              let newest = versions.last(where: { $0.header.kind != .members })
        else { return SpaceApplyResultModel() }
        let snapshot = try SpaceVersionBuilder.snapshot(of: newest, keychain: keychain)
        defer { snapshot.wipe() }
        return try SpaceSnapshotApplier(rows: rowWriter(tx), keys: copy keys)
            .apply(snapshot, repositoryID: record.repositoryID, scope: record.scope)
    }

    /// The repository (by GitHub id) and scope (by the environment's name on GitHub) a binding
    /// names in this vault.
    private func localScope(of binding: SpaceBindingModel, in tx: StoreTransaction) throws -> (repositoryID: RepoID, scope: ConfigScope)? {
        guard let repository = try RepoStore(database: session.database).fetch(githubID: binding.githubRepoID, in: tx) else {
            return nil
        }
        guard let name = binding.environmentName else { return (repository.id, .repository) }
        let key = EnvironmentNameValidator.foldKey(name)
        let environment = try ConfigStore(database: session.database)
            .fetchEnvironments(repositoryID: repository.id, in: tx)
            .first { EnvironmentNameValidator.foldKey($0.syncedName ?? $0.name) == key }
        return environment.map { (repository.id, .environment($0.id)) }
    }

    private func rowWriter(_ tx: StoreTransaction) -> SyncRowWriter {
        SyncRowWriter(database: session.database, tx: tx, now: clock.now)
    }
}
