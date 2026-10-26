import Foundation
import os
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// Environments, secrets and variables of the vault: every local edit, the reveal of a value,
/// and the live streams the repository detail, the scopes column and the "Sync N" label
/// observe (§7.1, §7.8, §10; M3, M5).
///
/// - Every mutation is one `VaultSession.write` transaction, so it needs an unlocked vault and
///   is serialized with DEK rotation. Values are normalized on entry (D32: trailing CR/LF
///   stripped, then checked for emptiness and size) and stored only as ciphertext plus a
///   row-bound fingerprint.
/// - Item edits follow SyncEngine's `ConfigItemEditPlanner`: coalescing, tombstone revival,
///   names unique per scope and kind by fold key, kind and scope immutable once synced
///   (Convert/Move creates a new row plus a tombstone), Revert, Discard all, and Fill.
/// - Edits are refused where the viewer cannot write (`RepoCapabilityModel` with the injected
///   WRITE policy, §2 Permissions). Revert and Discard all only remove local changes and are
///   always allowed.
/// - Observation streams need no keys and work while locked.
public struct ConfigRepository: Sendable {
    public let session: VaultSession
    private let clock: any VaultClock
    let writePolicy: WriteCollaboratorPolicy

    public init(
        session: VaultSession,
        clock: any VaultClock = SystemClock(),
        writePolicy: WriteCollaboratorPolicy = .default
    ) {
        self.session = session
        self.clock = clock
        self.writePolicy = writePolicy
    }

    var store: ConfigStore {
        ConfigStore(database: session.database)
    }

    // MARK: - Environments

    /// Creates an environment (§7.1). Re-creating the name of a deleted environment revives that
    /// tombstone with its synced items.
    ///
    /// - Throws: `.validation` for an invalid name (NFC, 255 scalars, path-safe) or one whose
    ///   fold key is taken (`.duplicateName`) or held by a pending rename or deletion
    ///   (`.nameReservedByPendingChange`); `.readOnly`; `.tooManyBranchPatterns`.
    @discardableResult
    public func createEnvironment(
        in repositoryID: RepoID,
        name: String,
        policy: BranchPolicyDraftModel = .all
    ) throws(ConfigRepositoryError) -> EnvironmentID {
        try write { _, tx, now in
            try environmentEditor(tx, now: now).create(in: repositoryID, name: name, policy: policy)
        }
    }

    /// Renames an environment locally. A never-synced environment or a case-only change stays
    /// local; a synced environment with a new name is recreated on GitHub by the next Sync
    /// (§7.6), which is what the result reports.
    @discardableResult
    public func renameEnvironment(_ id: EnvironmentID, to name: String) throws(ConfigRepositoryError)
        -> EnvironmentRenameKind
    {
        try write { _, tx, now in
            try environmentEditor(tx, now: now).rename(id, to: name)
        }
    }

    /// Deletes an environment: removed when never synced, otherwise a tombstone pending
    /// deletion on GitHub (its items go with it).
    public func deleteEnvironment(_ id: EnvironmentID) throws(ConfigRepositoryError) {
        try write { _, tx, now in
            try environmentEditor(tx, now: now).delete(id)
        }
    }

    /// Sets the environment's deployment branch policy.
    public func updateBranchPolicy(_ id: EnvironmentID, to policy: BranchPolicyDraftModel) throws(ConfigRepositoryError) {
        try write { _, tx, now in
            try environmentEditor(tx, now: now).updatePolicy(id, to: policy)
        }
    }

    /// Drops the environment's own local changes (name, policy, patterns, deletion). A
    /// never-synced environment is removed with its items.
    public func revertEnvironment(_ id: EnvironmentID) throws(ConfigRepositoryError) {
        try write { _, tx, now in
            try environmentEditor(tx, now: now).revert(id)
        }
    }

    /// Duplicates an environment into a new one named `name` (M5 `DuplicateEnvironmentScreen`):
    /// the policy and active patterns are copied unsynced, and every live item is copied as a
    /// pending add with its value re-encrypted under the new row's identity. Value-missing
    /// secrets stay value-missing (§7.8), so Sync blocks them until they are filled.
    @discardableResult
    public func duplicateEnvironment(_ sourceID: EnvironmentID, as name: String) throws(ConfigRepositoryError)
        -> EnvironmentID
    {
        try write { keys, tx, now in
            let editor = environmentEditor(tx, now: now)
            let (source, snapshot) = try editor.load(environment: sourceID)
            try editor.requireEditable(snapshot.repository)
            let validName = try EnvironmentEditor.validated(name)
            let key = EnvironmentNameValidator.foldKey(validName)
            if snapshot.environments.contains(where: { $0.isDeleted && $0.nameKey == key }) {
                throw ConfigRepositoryError.validation(.nameReservedByPendingChange)
            }
            let patterns = source.branchPolicy.activePatterns.map {
                BranchPatternDraftModel(pattern: $0.pattern, type: $0.type)
            }
            let policy: BranchPolicyDraftModel = switch source.branchPolicy {
            case .all: .all
            case .protectedBranches: .protectedBranches
            case .custom: .custom(patterns)
            }
            let targetID = try editor.create(in: source.repositoryID, name: validName, policy: policy)
            let records = try store.fetchItemRecords(
                repositoryID: source.repositoryID,
                scope: .environment(sourceID),
                in: tx
            )
            for record in records where !record.isDeleted {
                try insertCopy(of: record, into: targetID, keys: keys, now: now, in: tx)
            }
            return targetID
        }
    }

    // MARK: - Items

    /// Adds a secret or variable (§7.1). Adding the name of a deleted item revives that
    /// tombstone. The value is normalized first (D32); `file` is the file it came from (1.0 F1).
    @discardableResult
    public func addItem(
        repositoryID: RepoID,
        scope: ConfigScope,
        kind: ConfigKind,
        name: String,
        value: SecretBytes,
        file: FileSecretModel? = nil
    ) throws(ConfigRepositoryError) -> ItemWriteResultModel {
        let normalized = try Self.normalize(value)
        defer { normalized.value.wipe() }
        let itemID = try batch(repositoryID: repositoryID) { batch in
            try batch.add(scope: scope, kind: kind, name: name, value: normalized.value, file: file)
        }
        return ItemWriteResultModel(itemID: itemID, didStripTrailingNewlines: normalized.didStripTrailingNewlines)
    }

    /// Replaces an item's local value. Editing back to the synced value leaves nothing pending.
    @discardableResult
    public func editValue(_ id: ConfigItemID, value: SecretBytes) throws(ConfigRepositoryError) -> ItemWriteResultModel {
        let normalized = try Self.normalize(value)
        defer { normalized.value.wipe() }
        try itemBatch(id) { batch in
            try batch.editValue(id, value: normalized.value)
        }
        return ItemWriteResultModel(itemID: id, didStripTrailingNewlines: normalized.didStripTrailingNewlines)
    }

    /// Renames an item. Returns the row now holding the item (a revived tombstone when the new
    /// name was deleted).
    @discardableResult
    public func renameItem(_ id: ConfigItemID, to name: String) throws(ConfigRepositoryError) -> ConfigItemID {
        try itemBatch(id) { batch in
            try batch.rename(id, to: name)
        }
    }

    /// Deletes an item: removed when never synced, otherwise a tombstone pending deletion.
    public func deleteItem(_ id: ConfigItemID) throws(ConfigRepositoryError) {
        try itemBatch(id) { batch in
            try batch.delete(id)
        }
    }

    /// Restores the synced name and value and clears the deletion and `force_push` (§7.1).
    public func revertItem(_ id: ConfigItemID) throws(ConfigRepositoryError) {
        try itemBatch(id) { batch in
            try batch.revert(id)
        }
    }

    /// Fills a value-missing secret (§7.1, §7.8). By default (v0.1.2) the vault is the source
    /// of truth: a secret on GitHub becomes a pending push (`force_push`, requested now, so a
    /// GitHub change made before this moment does not block it, D27). With
    /// `pushOnNextSync: false` ("Already matches GitHub") the value is taken as what GitHub
    /// already has and nothing is pending.
    @discardableResult
    public func fillValue(
        _ id: ConfigItemID,
        value: SecretBytes,
        pushOnNextSync: Bool = true
    ) throws(ConfigRepositoryError) -> ItemWriteResultModel {
        let normalized = try Self.normalize(value)
        defer { normalized.value.wipe() }
        try itemBatch(id) { batch in
            try batch.fill(id, value: normalized.value, pushOnNextSync: pushOnNextSync, isUserRequest: true)
        }
        return ItemWriteResultModel(itemID: id, didStripTrailingNewlines: normalized.didStripTrailingNewlines)
    }

    /// "Push on Next Sync" (v0.1.2): the next Sync re-sends the local value of a synced secret
    /// even when it did not change (`force_push`, requested now: D27 then blocks only a GitHub
    /// change made after this moment). Revert clears it. Only for secrets: variables are
    /// compared by value, so a differing variable is already pending or reported as drift.
    ///
    /// - Throws: `.edit(.pushNotApplicable)` for a variable, a deleted item, an item not on
    ///   GitHub or a value-missing secret (fill it instead); `.readOnly`; `.itemNotFound`.
    public func requestPush(_ id: ConfigItemID) throws(ConfigRepositoryError) {
        try itemBatch(id) { batch in
            try batch.requestPush(id)
        }
        Self.log.info("Push on next Sync requested for one secret")
    }

    // MARK: - Several items (v0.4.0)

    /// Deletes several items of one repository in one transaction: unsynced items are removed,
    /// synced ones become tombstones that the next Sync deletes on GitHub after the deletion
    /// review (§7.5). Nothing is written when one of them cannot be deleted.
    public func deleteItems(_ ids: [ConfigItemID], repositoryID: RepoID) throws(ConfigRepositoryError) {
        try batch(repositoryID: repositoryID) { batch in
            for id in ids {
                try batch.delete(id)
            }
        }
        Self.log.info("Deleted \(ids.count, privacy: .public) items")
    }

    /// Reverts several items of one repository in one transaction (``revertItem(_:)`` for each).
    /// Nothing is written when one of them cannot be reverted.
    public func revertItems(_ ids: [ConfigItemID], repositoryID: RepoID) throws(ConfigRepositoryError) {
        try batch(repositoryID: repositoryID) { batch in
            for id in ids {
                try batch.revert(id)
            }
        }
        Self.log.info("Reverted \(ids.count, privacy: .public) items")
    }

    /// Push on Next Sync for several secrets of one repository in one transaction
    /// (``requestPush(_:)`` for each). Nothing is written when one of them does not apply.
    public func requestPush(_ ids: [ConfigItemID], repositoryID: RepoID) throws(ConfigRepositoryError) {
        try batch(repositoryID: repositoryID) { batch in
            for id in ids {
                try batch.requestPush(id)
            }
        }
        Self.log.info("Push on next Sync requested for \(ids.count, privacy: .public) secrets")
    }

    // MARK: - Copy between scopes (v0.4.0) and repositories (v0.4.1)

    /// The names among `ids` that `scope` of `repositoryID` already holds (same kind, not
    /// deleted): the copy asks whether to replace or keep those items. The sources may belong to
    /// any repository or folder (v0.7.0); deleted and missing ids, and items already in that
    /// scope, are ignored here.
    public func copyConflicts(
        _ ids: [ConfigItemID],
        to scope: ConfigScope,
        repositoryID: RepoID
    ) throws(ConfigRepositoryError) -> [String] {
        try performConfig {
            let targets = try store.fetchItemRecords(repositoryID: repositoryID, scope: scope).filter { !$0.isDeleted }
            let taken = Set(targets.map { TargetKey(kind: $0.kind, name: GitHubNameValidator.foldKey($0.name)) })
            let place = ItemPlaceModel.scope(repositoryID: repositoryID, scope: scope)
            return try ids.compactMap { id in
                guard let source = try ItemCopySource.load(id, database: session.database),
                      !source.isDeleted,
                      !source.isIn(place),
                      taken.contains(TargetKey(kind: source.kind, name: GitHubNameValidator.foldKey(source.name)))
                else { return nil }
                return source.name
            }
        }
    }

    /// Copies items into `scope` of `repositoryID` in one transaction. The sources may be in any
    /// scope of any repository in the vault (v0.4.1), whatever account it belongs to, or in a
    /// folder (v0.7.0); the target must be editable by its own repository's account. Each item becomes a pending add there
    /// with its value encrypted for its new row, or, when the target already has the name,
    /// replaces that item's value or keeps it (`conflicts`).
    ///
    /// Every copied or replaced item is **linked** to its source (v0.4.1): both get the source's
    /// `link_id`, a new one when the source had none. A kept item is not linked. Secrets without
    /// a value are not copied (they are listed in the result). Nothing is written when one of
    /// them fails (an edit the account may not make, a full scope).
    @discardableResult
    public func copyItems(
        _ ids: [ConfigItemID],
        to scope: ConfigScope,
        repositoryID: RepoID,
        conflicts: ItemCopyConflictPolicy
    ) throws(ConfigRepositoryError) -> ItemCopyResultModel {
        let result = try write { keys, tx, now in
            var batch = try ItemEditBatch(
                repositoryID: repositoryID,
                keys: keys,
                tx: tx,
                store: store,
                now: now,
                writePolicy: writePolicy
            )
            try batch.requireEditable(scope)
            var result = ItemCopyResultModel()
            let place = ItemPlaceModel.scope(repositoryID: repositoryID, scope: scope)
            for id in ids {
                guard let source = try ItemCopySource.load(id, database: session.database, in: tx), !source.isDeleted else {
                    throw ConfigRepositoryError.itemNotFound
                }
                guard !source.isIn(place) else { continue }
                guard let value = try source.openValue(keys: keys) else {
                    result.withoutValue.append(source.name)
                    continue
                }
                defer { value.wipe() }
                let copyID: ConfigItemID
                if let existing = batch.liveRow(scope: scope, kind: source.kind, name: source.name) {
                    switch conflicts {
                    case .keep:
                        result.kept += 1
                        continue
                    case .replace:
                        try batch.editValue(existing.id, value: value, file: source.file)
                        copyID = existing.id
                        result.replaced += 1
                    }
                } else {
                    copyID = try batch.add(scope: scope, kind: source.kind, name: source.name, value: value, file: source.file)
                    result.added += 1
                }
                try source.link(copy: copyID, database: session.database, in: tx)
            }
            return result
        }
        Self.log.info("Copied \(result.added + result.replaced, privacy: .public) items to another scope")
        return result
    }

    /// The kind and folded name a copy target is matched on.
    struct TargetKey: Hashable {
        let kind: ConfigKind
        let name: String
    }

    /// "Convert to variable / Move to…" (D11): the item moves to `kind` and `scope` as a new row
    /// (or a revived tombstone there) and the source row is deleted. The app confirms a
    /// secret→variable conversion first (§5.13). A value-missing secret cannot become a
    /// variable (`.valueMissing`).
    @discardableResult
    public func moveItem(
        _ id: ConfigItemID,
        toKind kind: ConfigKind,
        scope: ConfigScope
    ) throws(ConfigRepositoryError) -> ConfigItemID {
        try itemBatch(id) { batch in
            try batch.move(id, kind: kind, scope: scope)
        }
    }

    /// Discard all (§7.1): reverts every environment and item of the repository with a local
    /// change. Never-synced environments and items are removed.
    public func discardAll(repositoryID: RepoID) throws(ConfigRepositoryError) {
        try write { keys, tx, now in
            let editor = environmentEditor(tx, now: now)
            let snapshot = try editor.load(repositoryID)
            for environment in snapshot.environments where EnvironmentEditor.hasPendingChange(environment) {
                try editor.revert(environment.id)
            }
            var batch = try ItemEditBatch(
                repositoryID: repositoryID,
                keys: keys,
                tx: tx,
                store: store,
                now: now,
                writePolicy: writePolicy
            )
            try batch.discardAll()
        }
        Self.log.info("Discarded local changes of one repository")
    }

    /// The decrypted local value of a repository or folder item (v0.7.0), for Reveal, Copy and
    /// Edit (§5.12). The caller wipes it.
    ///
    /// - Throws: `.valueMissing` for a value-missing secret (§7.8), `.itemNotFound`, `.vault`.
    public func reveal(_ id: ConfigItemID) throws(ConfigRepositoryError) -> SecretBytes {
        try performConfig {
            try session.read { keys, tx in
                guard let source = try ItemCopySource.load(id, database: session.database, in: tx) else {
                    throw ConfigRepositoryError.itemNotFound
                }
                guard let value = try source.openValue(keys: keys) else {
                    throw ConfigRepositoryError.valueMissing
                }
                return value
            }
        }
    }

    // MARK: - Reads

    /// The repository's change set (§7.1), or nil when the repository does not exist.
    public func changeSet(repositoryID: RepoID) throws(ConfigRepositoryError) -> ChangeSetModel? {
        try performConfig {
            try store.fetchPendingInputs(repositoryID: repositoryID).map {
                ChangeSetBuilder.build(RepoSnapshotMapper.snapshot($0))
            }
        }
    }

    /// The repository's scopes (§10 scopes column), from the stored rows.
    public func scopes(repositoryID: RepoID) throws(ConfigRepositoryError) -> [ConfigScopeSummaryModel] {
        try performConfig {
            guard let inputs = try store.fetchPendingInputs(repositoryID: repositoryID) else {
                throw ConfigRepositoryError.repositoryNotFound
            }
            return Self.scopeSummaries(inputs)
        }
    }

    /// The live environments of every repository in one read (1.0, the ⌘K palette), by
    /// repository, each in the scopes column's order; deleted ones left out.
    public func environmentsByRepository() throws(ConfigRepositoryError) -> [RepoID: [EnvironmentModel]] {
        try performConfig {
            Dictionary(grouping: try store.fetchAllEnvironments().filter { !$0.isDeleted }, by: \.repositoryID)
        }
    }

    // MARK: - Names

    /// The live secrets and variables whose name holds every word of `query` (any case), in
    /// every repository, folder, destination and organization (1.0 D6c5, ⌘K): names only, never
    /// a value; a name that starts with a word first. Empty for an empty query.
    public func itemNames(
        matching query: String,
        limit: Int = Limits.maxItemNameMatches
    ) throws(ConfigRepositoryError) -> [ItemNameMatchModel] {
        let words = query.split(whereSeparator: \.isWhitespace).map { $0.uppercased() }
        return try performConfig {
            try ItemNameStore(database: session.database).fetchMatches(containing: words, limit: limit)
        }
    }

    // MARK: - Observation

    /// Every repository (sidebar), now and after each change.
    public func observeRepositories() -> AsyncThrowingStream<[RepoModel], any Error> {
        RepoStore(database: session.database).observeAll()
    }

    /// The scopes column of one repository: "Repository" then each environment (tombstones
    /// included), with pending dots and value-missing counts. Ends with
    /// ``ConfigRepositoryError/repositoryNotFound`` when the repository is removed.
    public func observeScopes(repositoryID: RepoID) -> AsyncThrowingStream<[ConfigScopeSummaryModel], any Error> {
        ObservationMapper.map(store.observePendingInputs(repositoryID: repositoryID)) { inputs in
            guard let inputs else { throw ConfigRepositoryError.repositoryNotFound }
            return Self.scopeSummaries(inputs)
        }
    }

    /// The items of one scope (tombstones included), each with its `ConfigSyncStatus`.
    public func observeItems(
        repositoryID: RepoID,
        scope: ConfigScope
    ) -> AsyncThrowingStream<[ConfigItemModel], any Error> {
        store.observeItems(repositoryID: repositoryID, scope: scope)
    }

    /// Pending and blocked counts per repository and in total: the "Sync N" label and the dock
    /// badge (§10 Toolbar); with each repository's secrets without a value (the sidebar).
    public func observePendingCounts() -> AsyncThrowingStream<PendingCountsModel, any Error> {
        ObservationMapper.map(store.observeAllPendingInputs()) { all in
            Self.pendingCounts(all)
        }
    }

    /// The current counts (see ``observePendingCounts()``).
    public func pendingCounts() throws(ConfigRepositoryError) -> PendingCountsModel {
        try performConfig { Self.pendingCounts(try store.fetchAllPendingInputs()) }
    }

    // MARK: - Derived models

    static func pendingCounts(_ all: [RepoPendingInputsModel]) -> PendingCountsModel {
        var counts: [RepoID: RepoPendingCountModel] = [:]
        for inputs in all {
            let changeSet = ChangeSetBuilder.build(RepoSnapshotMapper.snapshot(inputs))
            // The scope list's own counts, so the repository row adds up what its scopes show.
            let liveScopes = scopeSummaries(inputs).filter { $0.environment?.isDeleted != true }
            counts[inputs.repository.id] = RepoPendingCountModel(
                pending: changeSet.pendingCount,
                blocked: changeSet.blocked.count,
                valueMissing: liveScopes.reduce(0) { $0 + $1.valueMissingCount }
            )
        }
        return PendingCountsModel(repositories: counts)
    }

    static func scopeSummaries(_ inputs: RepoPendingInputsModel) -> [ConfigScopeSummaryModel] {
        let items = inputs.items.map(RepoSnapshotMapper.item)
        func summary(_ scope: ConfigScope, environment: EnvironmentModel?) -> ConfigScopeSummaryModel {
            let scoped = items.filter { $0.scope == scope }
            let live = scoped.filter { !$0.isDeleted }
            let ownChange = environment.map(EnvironmentEditor.hasPendingChange) ?? false
            return ConfigScopeSummaryModel(
                scope: scope,
                environment: environment,
                itemCount: live.count,
                valueMissingCount: live.filter { $0.kind == .secret && !$0.hasValue }.count,
                hasPendingChanges: ownChange || scoped.contains(where: \.hasPendingChange)
            )
        }
        return [summary(.repository, environment: nil)]
            + inputs.environments.map { summary(.environment($0.id), environment: $0) }
    }

    // MARK: - Private

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: ConfigConstants.logCategory)

    private static func normalize(_ value: SecretBytes) throws(ConfigRepositoryError) -> ValueNormalizer.NormalizedValue {
        do {
            return try ValueNormalizer.normalize(value)
        } catch {
            throw .validation(error)
        }
    }

    private func environmentEditor(_ tx: StoreTransaction, now: Date) -> EnvironmentEditor {
        EnvironmentEditor(store: store, tx: tx, now: now, writePolicy: writePolicy)
    }

    /// One write transaction with the keys and the current time.
    func write<Result>(
        _ body: (borrowing UnlockedKeys, StoreTransaction, Date) throws -> Result
    ) throws(ConfigRepositoryError) -> Result {
        let now = clock.now
        return try performConfig {
            try session.write { keys, tx in try body(keys, tx, now) }
        }
    }

    /// One write transaction with an item batch over `repositoryID`.
    func batch<Result>(
        repositoryID: RepoID,
        _ body: (inout ItemEditBatch) throws -> Result
    ) throws(ConfigRepositoryError) -> Result {
        try write { keys, tx, now in
            var batch = try ItemEditBatch(
                repositoryID: repositoryID,
                keys: keys,
                tx: tx,
                store: store,
                now: now,
                writePolicy: writePolicy
            )
            return try body(&batch)
        }
    }

    /// One write transaction with an item batch over the repository of item `id`.
    private func itemBatch<Result>(
        _ id: ConfigItemID,
        _ body: (inout ItemEditBatch) throws -> Result
    ) throws(ConfigRepositoryError) -> Result {
        let repositoryID = try performConfig { () throws -> RepoID in
            guard let record = try store.fetchItemRecord(id: id) else { throw ConfigRepositoryError.itemNotFound }
            return record.repositoryID
        }
        return try batch(repositoryID: repositoryID, body)
    }

    /// Copies one item into another environment as a pending add (Duplicate).
    private func insertCopy(
        of record: ConfigItemRecord,
        into environmentID: EnvironmentID,
        keys: borrowing UnlockedKeys,
        now: Date,
        in tx: StoreTransaction
    ) throws {
        var copy = ConfigItemRecord(
            repositoryID: record.repositoryID,
            scope: .environment(environmentID),
            kind: record.kind,
            name: record.name,
            valueCiphertext: nil,
            valueFingerprint: nil,
            provenance: record.provenance == .share ? .share : .local,
            shareOrigin: record.provenance == .share ? record.shareOrigin : nil,
            createdAt: now,
            updatedAt: now
        )
        if let value = try ConfigFieldCipher.openValue(of: record, keys: keys) {
            defer { value.wipe() }
            try ConfigFieldCipher.setValue(value, on: &copy, keys: keys)
            // After setValue, which drops the label of a new value: the copy holds the same file.
            copy.file = record.file
        }
        try store.insertItem(copy, in: tx)
    }
}

/// Constants of the Config area.
enum ConfigConstants {
    static let logSubsystem = "io.fractalx.fxvault"
    static let logCategory = "config"
}
