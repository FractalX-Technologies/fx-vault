import Foundation
import GitHubKit
import os
import SharingKit
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// Who this Mac is in a space it creates or changes (its member entry and markers).
public struct SpaceLocalIdentityModel: Sendable, Hashable {
    public let login: String
    public let displayName: String
    public let macName: String

    public init(login: String, displayName: String, macName: String) {
        self.login = login
        self.displayName = displayName
        self.macName = macName
    }
}

/// Shared spaces (v0.6.0, tasks/todo.md S1–S9): one versioned source of truth per shared scope
/// between teammates, with no server.
///
/// - **Log.** Each space keeps its verified versions (`space_versions`, their wire form) and its
///   epoch keys sealed in the vault (`space_keys`, ``keyAAD(spaceID:epoch:)``). Every read
///   re-verifies the log from genesis (``SharingKit/SpaceLog``), so a tampered row is refused.
/// - **Versions** are full snapshots of what GitHub holds (``SpaceSnapshotBuilder``), created
///   only by a verified push (``SyncSpaceCoordinating``), a share (genesis) or a member change.
/// - **Marker.** GitHub's `FXVAULT_SPACE` variable serializes publishes: a claim before the
///   first write, a `published` marker after, each re-read. Sync does it for pushes; this
///   repository does it for genesis and member changes (``SpaceMarkerWriter``).
/// - **Teammates' versions** (``receive(_:spaceID:from:)``) are verified against the stored log,
///   stored, and applied to the scope's rows in the same transaction (``SpaceSnapshotApplier``).
public struct SpaceRepository: Sendable {
    public let session: VaultSession
    let schedulers: any GHSchedulerProviding
    let clock: any VaultClock

    static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "space")

    public init(session: VaultSession, schedulers: any GHSchedulerProviding, clock: any VaultClock = SystemClock()) {
        self.session = session
        self.schedulers = schedulers
        self.clock = clock
    }

    var store: SpaceStore {
        SpaceStore(database: session.database)
    }

    var team: TeamRepository {
        TeamRepository(session: session, clock: clock)
    }

    // MARK: - Spaces (no keys)

    /// Every space on this Mac.
    public func spaces() throws(SpaceRepositoryError) -> [SpaceSummaryModel] {
        try perform { try store.fetchSpaces().map(SpaceSummaryModel.init) }
    }

    /// ``spaces()`` now and after each change (works while locked).
    public func observeSpaces() -> AsyncThrowingStream<[SpaceSummaryModel], any Error> {
        ObservationMapper.map(store.observeSpaces()) { $0.map(SpaceSummaryModel.init) }
    }

    /// A space with its members, from its verified log.
    public func detail(_ id: SpaceID) throws(SpaceRepositoryError) -> SpaceDetailModel {
        try perform {
            try session.database.read { tx in
                let space = try load(id, in: tx)
                let device = try TeamStore(database: session.database).fetchIdentity(in: tx).flatMap { TeamDeviceID(hex: $0.deviceID) }
                let paired = Set(try TeamStore(database: session.database).fetchTeammates(in: tx).map(\.deviceID))
                let members = space.state.members.map { member in
                    SpaceMemberSummaryModel(
                        deviceID: member.deviceID.hex,
                        name: member.name,
                        login: member.login,
                        macName: member.macName,
                        isThisMac: member.deviceID == device,
                        isPaired: paired.contains(member.deviceID.hex)
                    )
                }
                return SpaceDetailModel(
                    summary: SpaceSummaryModel(record: space.record),
                    members: members,
                    isMember: device.map(space.state.isMember) ?? false
                )
            }
        }
    }

    // MARK: - Share (S1)

    /// Whether `scope` can be shared now: everything pushed and verified, and every secret's
    /// value known on this Mac (genesis describes what GitHub holds, values included).
    public func readiness(repositoryID: RepoID, scope: ConfigScope) throws(SpaceRepositoryError) -> SpaceReadinessModel {
        try perform {
            let states = try ConfigStore(database: session.database).fetchItemStates(repositoryID: repositoryID, scope: scope)
            var pending: [String] = []
            var missing: [String] = []
            for state in states {
                let model = state.model
                if model.syncStatus != .synced || state.verifyState != .verified {
                    pending.append(state.name)
                } else if !state.isDeleted, !state.hasValue {
                    missing.append(state.name)
                }
            }
            return SpaceReadinessModel(
                pendingNames: pending.sorted(),
                missingValueNames: missing.sorted(),
                itemCount: states.filter { !$0.isDeleted }.count
            )
        }
    }

    /// Shares `scope` with `teammateIDs` (S1): version 1 with every item as GitHub holds it,
    /// then the `published` marker on GitHub. Returns the new space.
    ///
    /// - Throws: `.scopeNotReady`, `.alreadyShared`, `.sharedOnGitHub` (a marker is already
    ///   there: someone shares this scope and can add you), `.teammateNotFound`,
    ///   `.repositoryNotOnGitHub`, `.github`. A marker write that fails after the space was
    ///   stored is not an error: launch reconciliation (or the next Sync) writes it.
    @discardableResult
    public func share(
        repositoryID: RepoID,
        scope: ConfigScope,
        with teammateIDs: [String],
        me: SpaceLocalIdentityModel,
        reason: String
    ) async throws(SpaceRepositoryError) -> SpaceID {
        guard try readiness(repositoryID: repositoryID, scope: scope).isReady else { throw .scopeNotReady }
        let existing = try perform { try session.database.read { try store.fetchSpace(repositoryID: repositoryID, scope: scope, in: $0) } }
        guard existing == nil else { throw .alreadyShared }
        let device = try teamCall { try team.deviceKeys() }
        let cards = try teamCall { try team.teammateCards() }
        let chosen = cards.filter { teammateIDs.contains($0.deviceID.hex) }
        guard chosen.count == Set(teammateIDs).count, !chosen.isEmpty else { throw .teammateNotFound }
        let target = try await markerTarget(repositoryID: repositoryID, scope: scope)
        guard try await target.listMarker() == nil else { throw .sharedOnGitHub }

        let me = device.card(login: me.login, displayName: me.displayName, macName: me.macName)
        let spaceID = SpaceID()
        let now = clock.now
        let genesis: SpaceVersionModel = try perform {
            try session.write { keys, tx in
                guard try store.fetchSpace(repositoryID: repositoryID, scope: scope, in: tx) == nil else {
                    throw SpaceRepositoryError.alreadyShared
                }
                let rows = try ConfigStore(database: session.database).fetchItemRecords(repositoryID: repositoryID, scope: scope, in: tx)
                let snapshot = try SpaceSnapshotBuilder.snapshot(of: rows, previous: nil, reason: reason, keys: keys)
                defer { snapshot.wipe() }
                guard snapshot.items.allSatisfy({ $0.value != nil }) else { throw SpaceRepositoryError.scopeNotReady }
                let (version, keychain) = try SpaceVersionBuilder.genesis(
                    spaceID: spaceID,
                    binding: target.binding,
                    members: ([me] + chosen).map(SpaceMemberModel.init(card:)),
                    snapshot: snapshot,
                    author: device,
                    at: now
                )
                try store.saveSpace(
                    SpaceRecord(
                        id: spaceID,
                        repositoryID: repositoryID,
                        scope: scope,
                        headVersion: 1,
                        headHash: version.hash,
                        epoch: 1,
                        claimedVersion: 1,
                        createdAt: now,
                        updatedAt: now
                    ),
                    in: tx
                )
                try store.appendVersion(Self.record(of: version), in: tx)
                try saveKeys(keychain, spaceID: spaceID, keys: keys, in: tx)
                return version
            }
        }
        Self.log.info("Shared a scope with \(chosen.count, privacy: .public) teammates")
        let marker = try perform {
            try SpaceMarkerModel.make(
                spaceID: spaceID,
                version: 1,
                state: .published,
                head: genesis.hash,
                login: me.login,
                author: device,
                at: now
            ).encoded()
        }
        if await target.write(marker, isUpdate: false) {
            try clearClaim(spaceID)
        }
        return spaceID
    }

    // MARK: - Members (S7)

    /// Adds paired teammates: every epoch key so far is wrapped for them (Q2: full history).
    public func addMembers(_ spaceID: SpaceID, teammateIDs: [String], me: SpaceLocalIdentityModel) async throws(SpaceRepositoryError) {
        let cards = try teamCall { try team.teammateCards() }
        let added = cards.filter { teammateIDs.contains($0.deviceID.hex) }
        guard added.count == Set(teammateIDs).count, !added.isEmpty else { throw .teammateNotFound }
        try await changeMembers(spaceID, me: me, reason: "") { members in
            members + added.map(SpaceMemberModel.init(card:)).filter { new in !members.contains { $0.deviceID == new.deviceID } }
        }
    }

    /// Removes member devices: a new epoch whose key only the remaining members get. Returns the
    /// secrets the removed devices received, to rotate on GitHub (cryptography only cuts future
    /// access).
    public func removeMembers(
        _ spaceID: SpaceID,
        deviceIDs: [String],
        me: SpaceLocalIdentityModel
    ) async throws(SpaceRepositoryError) -> SpaceRotationChecklistModel {
        let removed = Set(deviceIDs)
        try await changeMembers(spaceID, me: me, reason: "") { members in
            members.filter { !removed.contains($0.deviceID.hex) }
        }
        return try rotationChecklist(spaceID)
    }

    /// Every secret name in any content version of the space.
    public func rotationChecklist(_ spaceID: SpaceID) throws(SpaceRepositoryError) -> SpaceRotationChecklistModel {
        let names = try withKeychain(spaceID) { space, keychain in
            var names: Set<String> = []
            for version in space.versions where version.header.kind != .members {
                let snapshot = try SpaceVersionBuilder.snapshot(of: version, keychain: keychain)
                defer { snapshot.wipe() }
                for item in snapshot.items where item.kind == .secret {
                    names.insert(item.name)
                }
            }
            return names
        }
        return SpaceRotationChecklistModel(secretNames: names.sorted())
    }

    /// Claims the scope on GitHub, records a members version, then publishes it.
    private func changeMembers(
        _ spaceID: SpaceID,
        me: SpaceLocalIdentityModel,
        reason: String,
        _ next: @Sendable ([SpaceMemberModel]) -> [SpaceMemberModel]
    ) async throws(SpaceRepositoryError) {
        let record = try perform { try session.database.read { try store.fetchSpace(id: spaceID, in: $0) } }
        guard let record else { throw .spaceNotFound }
        let target = try await markerTarget(repositoryID: record.repositoryID, scope: record.scope)
        let listed = try await target.listMarker()
        let decision = try decideGate(spaceID, markerText: listed)
        guard decision.allowsPush else { throw .gate(decision) }
        let claim = try claimMarker(spaceID)
        guard await target.write(claim, isUpdate: listed != nil) else {
            try clearClaim(spaceID)
            throw .gate(.forked)
        }
        let device = try teamCall { try team.deviceKeys() }
        let now = clock.now
        let marker: String = try perform {
            try session.write { keys, tx in
                let space = try load(spaceID, in: tx)
                let members = next(space.state.members)
                guard !members.isEmpty, members.contains(where: { $0.deviceID == device.deviceID }) else {
                    throw SpaceRepositoryError.invalidMembers
                }
                let keychain = try keychain(of: space, keys: keys, in: tx)
                let (version, updated) = try SpaceVersionBuilder.members(
                    members,
                    state: space.state,
                    keychain: keychain,
                    reason: reason,
                    author: device,
                    at: now
                )
                try append(version, to: space.record, in: tx)
                try saveKeys(updated, spaceID: spaceID, keys: keys, in: tx)
                return try SpaceMarkerModel.make(
                    spaceID: spaceID,
                    version: version.header.version,
                    state: .published,
                    head: version.hash,
                    login: me.login,
                    author: device,
                    at: now
                ).encoded()
            }
        }
        if await target.write(marker, isUpdate: true) {
            try clearClaim(spaceID)
        }
        Self.log.info("Changed the members of a space")
    }

    // MARK: - History (S3)

    /// Every version, newest first, with its reason and the names it changed.
    public func history(_ spaceID: SpaceID) throws(SpaceRepositoryError) -> [SpaceVersionSummaryModel] {
        try withKeychain(spaceID) { space, keychain in
            var previous: SpaceSnapshotModel?
            var summaries: [SpaceVersionSummaryModel] = []
            var members: [TeamDeviceID: SpaceMemberModel] = [:]
            for version in space.versions {
                for member in version.keyring.members { members[member.deviceID] = member }
                let author = members[version.header.author]
                let snapshot = try SpaceVersionBuilder.snapshot(of: version, keychain: keychain)
                var changed: [SpaceChangedItemModel] = []
                if version.header.kind != .members {
                    changed = Self.changedItems(from: previous, to: snapshot)
                    previous?.wipe()
                    previous = snapshot
                } else {
                    snapshot.wipe()
                }
                summaries.append(SpaceVersionSummaryModel(
                    version: Int64(version.header.version),
                    kind: Self.kind(version.header.kind),
                    authorName: author?.name ?? version.header.author.hex,
                    authorMacName: author?.macName ?? "",
                    createdAt: version.header.createdAt,
                    reason: snapshot.reason,
                    changedItems: changed
                ))
            }
            previous?.wipe()
            return summaries.reversed()
        }
    }

    /// One item through the versions that changed it, newest first.
    public func itemHistory(_ spaceID: SpaceID, kind: ConfigKind, name: String) throws(SpaceRepositoryError) -> [SpaceItemVersionModel] {
        let key = SpaceItemKey(kind: kind, name: name)
        return try withKeychain(spaceID) { space, keychain in
            var entries: [SpaceItemVersionModel] = []
            var members: [TeamDeviceID: SpaceMemberModel] = [:]
            var last: (fingerprint: String?, present: Bool)?
            for version in space.versions {
                for member in version.keyring.members { members[member.deviceID] = member }
                guard version.header.kind != .members else { continue }
                let snapshot = try SpaceVersionBuilder.snapshot(of: version, keychain: keychain)
                defer { snapshot.wipe() }
                let item = snapshot.items.first { SpaceItemKey(kind: $0.kind, name: $0.name) == key }
                let fingerprint = item.flatMap { SpaceVersionBuilder.fingerprint($0, spaceID: spaceID, keychain: keychain) }
                let current = (fingerprint: fingerprint, present: item != nil)
                if let last, last.fingerprint == current.fingerprint, last.present == current.present { continue }
                if last == nil, item == nil { continue }
                last = current
                entries.append(SpaceItemVersionModel(
                    version: Int64(version.header.version),
                    authorName: members[version.header.author]?.name ?? version.header.author.hex,
                    createdAt: version.header.createdAt,
                    fingerprint: fingerprint,
                    isRemoved: item == nil
                ))
            }
            return entries.reversed()
        }
    }

    /// An item's value in a version (History › Reveal; the app asks for Touch ID or the
    /// password first). Nil when the version does not have it. The caller wipes the result.
    public func value(_ spaceID: SpaceID, version number: Int64, kind: ConfigKind, name: String) throws(SpaceRepositoryError) -> SecretBytes? {
        let key = SpaceItemKey(kind: kind, name: name)
        return try withKeychain(spaceID) { space, keychain in
            guard let version = space.versions.first(where: { Int64($0.header.version) == number }) else {
                throw SpaceRepositoryError.spaceNotFound
            }
            let snapshot = try SpaceVersionBuilder.snapshot(of: version, keychain: keychain)
            defer { snapshot.wipe() }
            return snapshot.items.first { SpaceItemKey(kind: $0.kind, name: $0.name) == key }?.value?.copy()
        }
    }

    /// Stages an older value as a local change of the item (Restore This Value); its push is a
    /// new version. Re-adds the item when it was removed since.
    public func restore(
        _ spaceID: SpaceID,
        version: Int64,
        kind: ConfigKind,
        name: String,
        writePolicy: WriteCollaboratorPolicy = .default
    ) throws(SpaceRepositoryError) {
        guard let value = try self.value(spaceID, version: version, kind: kind, name: name) else { throw .spaceNotFound }
        defer { value.wipe() }
        let record = try perform { try session.database.read { try store.fetchSpace(id: spaceID, in: $0) } }
        guard let record else { throw .spaceNotFound }
        let config = ConfigRepository(session: session, clock: clock, writePolicy: writePolicy)
        let key = SpaceItemKey(kind: kind, name: name)
        do {
            let rows = try ConfigStore(database: session.database).fetchItemStates(repositoryID: record.repositoryID, scope: record.scope)
            if let row = rows.first(where: { !$0.isDeleted && SpaceItemKey(kind: $0.kind, name: $0.name) == key }) {
                try config.editValue(row.id, value: value)
            } else {
                try config.addItem(repositoryID: record.repositoryID, scope: record.scope, kind: kind, name: name, value: value)
            }
        } catch let error as ConfigRepositoryError {
            throw .config(error)
        } catch {
            throw .wrap(error)
        }
    }

    // MARK: - Internal

    /// A space and its verified log.
    struct LoadedSpace {
        let record: SpaceRecord
        let versions: [SpaceVersionModel]
        let state: SpaceStateModel
    }

    /// Loads and re-verifies a space's log; the stored head must match it.
    func load(_ id: SpaceID, in tx: StoreTransaction) throws -> LoadedSpace {
        guard let record = try store.fetchSpace(id: id, in: tx) else { throw SpaceRepositoryError.spaceNotFound }
        let versions = try store.fetchVersions(spaceID: id, in: tx).map { try SpaceVersionModel.decode($0.data) }
        let state = try SpaceLog.verify(versions, spaceID: id)
        guard Int64(state.headVersion) == record.headVersion, state.headHash == record.headHash else {
            throw SpaceLogFailure.parentMismatch
        }
        return LoadedSpace(record: record, versions: versions, state: state)
    }

    /// Appends a verified version and moves the head.
    func append(_ version: SpaceVersionModel, to record: SpaceRecord, in tx: StoreTransaction) throws {
        try store.appendVersion(Self.record(of: version), in: tx)
        var updated = record
        updated.headVersion = Int64(version.header.version)
        updated.headHash = version.hash
        updated.epoch = Int64(version.header.epoch)
        updated.updatedAt = clock.now
        try store.saveSpace(updated, in: tx)
    }

    static func record(of version: SpaceVersionModel) -> SpaceVersionRecord {
        SpaceVersionRecord(
            spaceID: version.header.spaceID,
            version: Int64(version.header.version),
            kind: Int64(version.header.kind.rawValue),
            authorDeviceID: version.header.author.hex,
            createdAt: version.header.createdAt,
            hash: version.hash,
            data: version.encoded()
        )
    }

    /// The epoch keys this Mac stored for the space.
    func keychain(of space: LoadedSpace, keys: borrowing UnlockedKeys, in tx: StoreTransaction) throws -> SpaceKeychain {
        var keychain = SpaceKeychain()
        for row in try store.fetchKeys(spaceID: space.record.id, in: tx) {
            let bytes = try keys.open(row.keyCiphertext, for: Self.keyAAD(spaceID: row.spaceID, epoch: row.epoch))
            defer { bytes.wipe() }
            keychain.importKey(bytes, epoch: UInt32(clamping: row.epoch))
        }
        return keychain
    }

    /// Stores every epoch key of `keychain` this Mac does not have yet.
    func saveKeys(_ keychain: SpaceKeychain, spaceID: SpaceID, keys: borrowing UnlockedKeys, in tx: StoreTransaction) throws {
        let stored = Set(try store.fetchKeys(spaceID: spaceID, in: tx).map(\.epoch))
        for epoch in keychain.epochs where !stored.contains(Int64(epoch)) {
            guard let bytes = keychain.exportKey(epoch) else { continue }
            defer { bytes.wipe() }
            try store.saveKey(
                SpaceKeyRecord(
                    spaceID: spaceID,
                    epoch: Int64(epoch),
                    keyCiphertext: try keys.seal(bytes, for: Self.keyAAD(spaceID: spaceID, epoch: Int64(epoch)))
                ),
                in: tx
            )
        }
    }

    /// `space_keys.key_ct`: bound to the space and the epoch.
    static func keyAAD(spaceID: SpaceID, epoch: Int64) -> SecretFieldAAD {
        var rowKey = Data(spaceID.bytes)
        rowKey.append(contentsOf: withUnsafeBytes(of: UInt32(clamping: epoch).bigEndian) { Array($0) })
        return SecretFieldAAD(table: SpaceKeyRecord.databaseTableName, column: "key_ct", rowKey: rowKey)
    }

    /// Runs `body` over a space's verified log and its keychain (vault unlocked).
    func withKeychain<Result>(
        _ spaceID: SpaceID,
        _ body: (LoadedSpace, SpaceKeychain) throws -> Result
    ) throws(SpaceRepositoryError) -> Result {
        try perform {
            try session.read { keys, tx in
                let space = try load(spaceID, in: tx)
                return try body(space, try keychain(of: space, keys: keys, in: tx))
            }
        }
    }

    func perform<Result>(_ body: () throws -> Result) throws(SpaceRepositoryError) -> Result {
        do {
            return try body()
        } catch {
            throw SpaceRepositoryError.wrap(error)
        }
    }

    func teamCall<Result>(_ body: () throws -> Result) throws(SpaceRepositoryError) -> Result {
        do {
            return try body()
        } catch let error as TeamRepositoryError {
            switch error {
            case .vault(let vault): throw .vault(vault)
            case .store(let store): throw .store(store)
            case .teammateNotFound: throw .teammateNotFound
            case .keys, .unexpected: throw .unexpected
            }
        } catch {
            throw .unexpected
        }
    }

    static func kind(_ kind: SpaceVersionKind) -> SpaceVersionSummaryModel.Kind {
        switch kind {
        case .genesis: .shared
        case .publish: .published
        case .members: .members
        }
    }

    /// Items added, removed, or with another value or GitHub date, by name.
    static func changedItems(from previous: SpaceSnapshotModel?, to next: SpaceSnapshotModel) -> [SpaceChangedItemModel] {
        let before = Dictionary(
            (previous?.items ?? []).map { (SpaceItemKey(kind: $0.kind, name: $0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var changed: Set<SpaceChangedItemModel> = []
        var seen: Set<SpaceItemKey> = []
        for item in next.items {
            let key = SpaceItemKey(kind: item.kind, name: item.name)
            seen.insert(key)
            if let old = before[key],
               old.githubUpdatedAt == item.githubUpdatedAt,
               SpaceSnapshotBuilder.sameValue(old.value, item.value) {
                continue
            }
            changed.insert(SpaceChangedItemModel(kind: item.kind, name: item.name))
        }
        for (key, item) in before where !seen.contains(key) {
            changed.insert(SpaceChangedItemModel(kind: item.kind, name: item.name))
        }
        return changed.sorted { ($0.name, $0.kind.rawValue) < ($1.name, $1.kind.rawValue) }
    }
}
