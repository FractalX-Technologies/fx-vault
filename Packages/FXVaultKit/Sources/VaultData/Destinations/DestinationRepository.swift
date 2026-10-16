import Foundation
import os
import VaultCore
import VaultCrypto
import VaultStore

/// Runtime destinations of repositories and their items (v0.8.0, tasks/todo.md R1–R3), and the
/// provider connections (Supabase and Vercel tokens) they use.
///
/// - Every mutation is one `VaultSession.write` transaction and stays local until the next Sync
///   (``DestinationSyncRepository``), which is the only path that reaches a provider.
/// - Values are normalized on entry (D32) and stored only as ciphertext bound to row,
///   destination, kind and name (`DestinationFieldAAD`) plus a row-bound fingerprint.
/// - Copies into a destination come from any repository scope, folder or destination and are
///   linked to their source.
/// - Removing a destination or a connection never deletes anything remotely.
/// - Observation streams need no keys and work while locked.
public struct DestinationRepository: Sendable {
    public let session: VaultSession
    private let clock: any VaultClock

    public init(session: VaultSession, clock: any VaultClock = SystemClock()) {
        self.session = session
        self.clock = clock
    }

    var store: DestinationStore {
        DestinationStore(database: session.database)
    }

    // MARK: - Destinations

    /// Adds a destination to a repository at the end of its RUNTIME section.
    ///
    /// - Throws: `.validation` for an invalid target or stage, `.repositoryNotFound`,
    ///   `.connectionNotFound` (missing, or for another provider), `.destinationExists`,
    ///   `.tooManyDestinations`.
    @discardableResult
    public func createDestination(
        repositoryID: RepoID,
        target: DestinationTargetModel,
        stage: String?,
        connectionID: ConnectionID?
    ) throws(ConfigRepositoryError) -> DestinationID {
        let validTarget = try performConfig { try DestinationRules.validate(target) }
        let validStage = try Self.validStage(stage)
        let id = try write { _, tx, now in
            guard try RepoStore(database: session.database).fetch(id: repositoryID, in: tx) != nil else {
                throw ConfigRepositoryError.repositoryNotFound
            }
            try requireConnection(connectionID, for: validTarget.provider, in: tx)
            guard try store.countDestinations(repositoryID: repositoryID, in: tx) < Limits.maxDestinationsPerRepository else {
                throw ConfigRepositoryError.tooManyDestinations(limit: Limits.maxDestinationsPerRepository)
            }
            let existing = try store.fetchDestinationRecords(repositoryID: repositoryID, in: tx)
            guard !existing.contains(where: { $0.targetKey == validTarget.targetKey }) else {
                throw ConfigRepositoryError.destinationExists
            }
            let record = DestinationRecord(
                repositoryID: repositoryID,
                target: validTarget,
                stage: validStage,
                connectionID: validTarget.provider.usesConnection ? connectionID : nil,
                sortOrder: try store.nextSortOrder(repositoryID: repositoryID, in: tx),
                createdAt: now,
                updatedAt: now
            )
            try store.insertDestination(record, in: tx)
            return record.id
        }
        Self.log.info("Added a \(validTarget.provider.rawValue, privacy: .public) destination")
        return id
    }

    /// Changes a destination's stage and (Supabase, Vercel) its connection. The target itself
    /// never changes: add another destination instead.
    public func updateDestination(_ id: DestinationID, stage: String?, connectionID: ConnectionID?) throws(ConfigRepositoryError) {
        let validStage = try Self.validStage(stage)
        try write { _, tx, now in
            guard var record = try store.fetchDestination(id: id, in: tx) else { throw ConfigRepositoryError.destinationNotFound }
            try requireConnection(connectionID, for: record.provider, in: tx)
            record.setStage(validStage)
            record.connectionID = record.provider.usesConnection ? connectionID : nil
            record.updatedAt = now
            try store.updateDestination(record, in: tx)
        }
    }

    /// Removes a destination and its items from the vault. Nothing is deleted remotely; their
    /// linked copies elsewhere stay where they are.
    public func deleteDestination(_ id: DestinationID) throws(ConfigRepositoryError) {
        try write { _, tx, _ in
            guard try store.deleteDestination(id: id, in: tx) else { throw ConfigRepositoryError.destinationNotFound }
        }
        Self.log.info("Removed a destination")
    }

    /// Puts a repository's destinations in the order of `ids`, which must list each once.
    public func reorderDestinations(_ ids: [DestinationID], repositoryID: RepoID) throws(ConfigRepositoryError) {
        try write { _, tx, now in
            let destinations = try store.fetchDestinationRecords(repositoryID: repositoryID, in: tx)
            guard Set(ids) == Set(destinations.map(\.id)), ids.count == destinations.count else {
                throw ConfigRepositoryError.destinationNotFound
            }
            let byID = Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0) })
            for (order, id) in ids.enumerated() {
                guard var destination = byID[id], destination.sortOrder != order else { continue }
                destination.sortOrder = order
                destination.updatedAt = now
                try store.updateDestination(destination, in: tx)
            }
        }
    }

    /// One destination with its counts, or nil.
    public func destination(_ id: DestinationID) throws(ConfigRepositoryError) -> DestinationModel? {
        try performConfig {
            guard let record = try store.fetchDestination(id: id) else { return nil }
            return try store.fetchDestinations(repositoryID: record.repositoryID).first { $0.id == id }
        }
    }

    /// The destinations of a repository with their counts.
    public func destinations(repositoryID: RepoID) throws(ConfigRepositoryError) -> [DestinationModel] {
        try performConfig { try store.fetchDestinations(repositoryID: repositoryID) }
    }

    /// The destinations of a repository, now and after each change.
    public func observeDestinations(repositoryID: RepoID) -> AsyncThrowingStream<[DestinationModel], any Error> {
        store.observeDestinations(repositoryID: repositoryID)
    }

    /// Pending destination changes per repository (added to the Sync badge).
    public func observePendingCounts() -> AsyncThrowingStream<[RepoID: Int], any Error> {
        store.observePendingCounts()
    }

    /// Pending destination changes per repository.
    public func pendingCounts() throws(ConfigRepositoryError) -> [RepoID: Int] {
        try performConfig { try store.fetchPendingCounts() }
    }

    // MARK: - Items

    public func items(destinationID: DestinationID) throws(ConfigRepositoryError) -> [DestinationItemModel] {
        try performConfig { try store.fetchItems(destinationID: destinationID) }
    }

    public func observeItems(destinationID: DestinationID) -> AsyncThrowingStream<[DestinationItemModel], any Error> {
        store.observeItems(destinationID: destinationID)
    }

    /// Adds a secret or variable (a variable becomes a secret where the provider holds secrets
    /// only). The value is normalized first (D32).
    @discardableResult
    public func addItem(
        destinationID: DestinationID,
        kind: ConfigKind,
        name: String,
        value: SecretBytes
    ) throws(ConfigRepositoryError) -> ItemWriteResultModel {
        let normalized = try Self.normalize(value)
        defer { normalized.value.wipe() }
        let id = try write { keys, tx, now in
            try writer(keys, tx, now).add(destinationID: destinationID, kind: kind, name: name, value: normalized.value)
        }
        return ItemWriteResultModel(itemID: id, didStripTrailingNewlines: normalized.didStripTrailingNewlines)
    }

    /// Saves an edit in one transaction: name and kind, then a new value when `value` is given.
    @discardableResult
    public func editItem(
        _ id: ConfigItemID,
        name: String,
        kind: ConfigKind,
        value: SecretBytes?
    ) throws(ConfigRepositoryError) -> ItemWriteResultModel {
        let normalized = try value.map { value throws(ConfigRepositoryError) in try Self.normalize(value) }
        defer { normalized?.value.wipe() }
        let holder = try write { keys, tx, now in
            let writer = writer(keys, tx, now)
            let holder = try writer.update(id, name: name, kind: kind)
            if let normalized {
                try writer.editValue(holder, value: normalized.value)
            }
            return holder
        }
        return ItemWriteResultModel(itemID: holder, didStripTrailingNewlines: normalized?.didStripTrailingNewlines ?? false)
    }

    /// Fills a value the vault does not have. With `alreadyMatchesRemote` nothing is pushed.
    @discardableResult
    public func fillValue(
        _ id: ConfigItemID,
        value: SecretBytes,
        alreadyMatchesRemote: Bool
    ) throws(ConfigRepositoryError) -> ItemWriteResultModel {
        let normalized = try Self.normalize(value)
        defer { normalized.value.wipe() }
        try write { keys, tx, now in
            try writer(keys, tx, now).fill(id, value: normalized.value, alreadyMatchesRemote: alreadyMatchesRemote)
        }
        return ItemWriteResultModel(itemID: id, didStripTrailingNewlines: normalized.didStripTrailingNewlines)
    }

    /// Deletes items (pending deletions remotely for pushed ones).
    public func deleteItems(_ ids: [ConfigItemID]) throws(ConfigRepositoryError) {
        try write { keys, tx, now in
            let writer = writer(keys, tx, now)
            for id in ids {
                try writer.delete(id)
            }
        }
    }

    /// Reverts pending deletions and adds.
    public func revertItems(_ ids: [ConfigItemID]) throws(ConfigRepositoryError) {
        try write { keys, tx, now in
            let writer = writer(keys, tx, now)
            for id in ids {
                try writer.revert(id)
            }
        }
    }

    /// Push on Next Sync.
    public func requestPush(_ ids: [ConfigItemID]) throws(ConfigRepositoryError) {
        try write { keys, tx, now in
            let writer = writer(keys, tx, now)
            for id in ids {
                try writer.requestPush(id)
            }
        }
    }

    /// "Mark as Public" (R10).
    public func setPublicAllowed(_ id: ConfigItemID, allowed: Bool) throws(ConfigRepositoryError) {
        try write { keys, tx, now in
            try writer(keys, tx, now).setPublicAllowed(id, allowed)
        }
    }

    /// The decrypted value of a destination item. The caller wipes it.
    public func reveal(_ id: ConfigItemID) throws(ConfigRepositoryError) -> SecretBytes {
        try performConfig {
            try session.read { keys, tx in
                guard let record = try store.fetchItemRecord(id: id, in: tx) else {
                    throw ConfigRepositoryError.itemNotFound
                }
                guard let value = try DestinationFieldCipher.openValue(of: record, keys: keys) else {
                    throw ConfigRepositoryError.valueMissing
                }
                return value
            }
        }
    }

    // MARK: - Copy and paste

    /// The names among `ids` that the destination already holds: the copy asks whether to replace
    /// or keep them. Deleted and missing ids, and items already there, are ignored.
    public func copyConflicts(_ ids: [ConfigItemID], to destinationID: DestinationID) throws(ConfigRepositoryError) -> [String] {
        try performConfig {
            try session.database.read { tx in
                let taken = Set(try store.fetchItemRecords(destinationID: destinationID, in: tx)
                    .filter { !$0.isDeleted }
                    .map { GitHubNameValidator.foldKey($0.name) })
                return try ids.compactMap { id in
                    guard let source = try ItemCopySource.load(id, database: session.database, in: tx),
                          !source.isDeleted,
                          !source.isIn(.destination(destinationID)),
                          taken.contains(GitHubNameValidator.foldKey(source.name))
                    else { return nil }
                    return source.name
                }
            }
        }
    }

    /// Copies items into a destination in one transaction, each linked to its source. A name the
    /// destination already has is replaced or kept; value-missing secrets are not copied;
    /// variables become secrets where the provider holds secrets only (both listed in the
    /// result). Nothing is written when one of them fails.
    @discardableResult
    public func copyItems(
        _ ids: [ConfigItemID],
        to destinationID: DestinationID,
        conflicts: ItemCopyConflictPolicy
    ) throws(ConfigRepositoryError) -> ItemCopyResultModel {
        try write { keys, tx, now in
            let writer = writer(keys, tx, now)
            let destination = try writer.requireDestination(destinationID)
            var result = ItemCopyResultModel()
            for id in ids {
                guard let source = try ItemCopySource.load(id, database: session.database, in: tx), !source.isDeleted else {
                    throw ConfigRepositoryError.itemNotFound
                }
                guard !source.isIn(.destination(destinationID)) else { continue }
                guard let value = try source.openValue(keys: keys) else {
                    result.withoutValue.append(source.name)
                    continue
                }
                defer { value.wipe() }
                let copyID: ConfigItemID
                if let existing = try writer.liveRow(destinationID: destinationID, name: source.name) {
                    switch conflicts {
                    case .keep:
                        result.kept += 1
                        continue
                    case .replace:
                        try writer.editValue(existing.id, value: value)
                        copyID = existing.id
                        result.replaced += 1
                    }
                } else {
                    copyID = try writer.add(destinationID: destinationID, kind: source.kind, name: source.name, value: value)
                    result.added += 1
                }
                if destination.provider.storedKind(for: source.kind) != source.kind {
                    result.madeSecret.append(source.name)
                }
                try source.link(copy: copyID, database: session.database, in: tx)
            }
            return result
        }
    }

    // MARK: - Connections

    /// Every provider connection, without tokens.
    public func connections() throws(ConfigRepositoryError) -> [ConnectionModel] {
        try performConfig { try store.fetchConnections() }
    }

    public func observeConnections() -> AsyncThrowingStream<[ConnectionModel], any Error> {
        store.observeConnections()
    }

    /// Stores a token for Supabase or Vercel, sealed in the vault. `accountHint` is what the
    /// provider reported when the token was checked (never the token). Does not wipe `token`.
    @discardableResult
    public func addConnection(
        provider: DestinationProvider,
        label: String,
        token: SecretBytes,
        accountHint: String?
    ) throws(ConfigRepositoryError) -> ConnectionID {
        guard provider.usesConnection else { throw .connectionNotFound }
        let validLabel = try performConfig { try FolderNameValidator.validate(label) }
        guard token.count > 0 else { throw .validation(.emptyValue) }
        return try write { keys, tx, now in
            guard try store.countConnections(in: tx) < Limits.maxConnections else {
                throw ConfigRepositoryError.tooManyConnections(limit: Limits.maxConnections)
            }
            let id = ConnectionID()
            let record = ConnectionRecord(
                id: id,
                provider: provider,
                label: validLabel,
                tokenCiphertext: try ConnectionTokenCipher.seal(token, for: id, keys: keys),
                accountHint: Self.sanitizedHint(accountHint),
                lastValidatedAt: now,
                createdAt: now,
                updatedAt: now
            )
            try store.insertConnection(record, in: tx)
            return id
        }
    }

    /// Renames a connection.
    public func renameConnection(_ id: ConnectionID, to label: String) throws(ConfigRepositoryError) {
        let validLabel = try performConfig { try FolderNameValidator.validate(label) }
        try write { _, tx, now in
            guard var record = try store.fetchConnection(id: id, in: tx) else { throw ConfigRepositoryError.connectionNotFound }
            record.label = validLabel
            record.updatedAt = now
            try store.updateConnection(record, in: tx)
        }
    }

    /// Replaces a connection's token (a rotated token).
    public func replaceToken(of id: ConnectionID, with token: SecretBytes, accountHint: String?) throws(ConfigRepositoryError) {
        guard token.count > 0 else { throw .validation(.emptyValue) }
        try write { keys, tx, now in
            guard var record = try store.fetchConnection(id: id, in: tx) else { throw ConfigRepositoryError.connectionNotFound }
            record.tokenCiphertext = try ConnectionTokenCipher.seal(token, for: id, keys: keys)
            record.accountHint = Self.sanitizedHint(accountHint)
            record.lastValidatedAt = now
            record.updatedAt = now
            try store.updateConnection(record, in: tx)
        }
    }

    /// Removes a connection. Its destinations stay, with no connection, until another is chosen.
    public func deleteConnection(_ id: ConnectionID) throws(ConfigRepositoryError) {
        try write { _, tx, _ in
            guard try store.deleteConnection(id: id, in: tx) else { throw ConfigRepositoryError.connectionNotFound }
        }
    }

    /// The decrypted token of a connection, for a request. The caller wipes it.
    func token(of id: ConnectionID) throws(ConfigRepositoryError) -> SecretBytes {
        try performConfig {
            try session.read { keys, tx in
                guard let record = try store.fetchConnection(id: id, in: tx) else {
                    throw ConfigRepositoryError.connectionNotFound
                }
                return try ConnectionTokenCipher.openToken(of: record, keys: keys)
            }
        }
    }

    // MARK: - Private

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "destinations")
    /// Longest account hint kept, in characters.
    private static let maxHintLength = 255

    static func validStage(_ stage: String?) throws(ConfigRepositoryError) -> String? {
        guard let stage, !stage.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try performConfig { try EnvironmentNameValidator.validate(stage) }
    }

    private static func sanitizedHint(_ hint: String?) -> String? {
        guard let hint else { return nil }
        let clean = String(UnicodeScalarPolicy.removingDisallowedAndInvisible(from: hint).prefix(maxHintLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static func normalize(_ value: SecretBytes) throws(ConfigRepositoryError) -> ValueNormalizer.NormalizedValue {
        do {
            return try ValueNormalizer.normalize(value)
        } catch {
            throw .validation(error)
        }
    }

    private func requireConnection(_ id: ConnectionID?, for provider: DestinationProvider, in tx: StoreTransaction) throws {
        guard provider.usesConnection else { return }
        guard let id, let connection = try store.fetchConnection(id: id, in: tx), connection.provider == provider else {
            throw ConfigRepositoryError.connectionNotFound
        }
    }

    private func writer(_ keys: borrowing UnlockedKeys, _ tx: StoreTransaction, _ now: Date) -> DestinationItemWriter {
        DestinationItemWriter(store: store, keys: keys, tx: tx, now: now)
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
}
