import Foundation
import os
import VaultCore
import VaultCrypto
import VaultStore

/// Runtime destinations of repositories and their items (v0.8.0, tasks/todo.md R1–R3), and the
/// Key Vaults of their own (1.0, B8b).
///
/// - Every mutation is one `VaultSession.write` transaction and stays local until the next Sync
///   (``DestinationSyncRepository``), which is the only path that reaches a provider.
/// - Values are normalized on entry (D32) and stored only as ciphertext bound to row,
///   destination, kind and name (`DestinationFieldAAD`) plus a row-bound fingerprint.
/// - Copies into a destination come from any repository scope, folder or destination and are
///   linked to their source.
/// - Removing a destination never deletes anything remotely.
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

    /// Adds a destination to a repository at the end of its RUNTIME section, or with a nil
    /// `repositoryID` a Key Vault of its own (1.0), listed beside GitHub.
    ///
    /// - Throws: `.validation` for an invalid target or stage, `.repositoryNotFound`,
    ///   `.destinationExists`, `.tooManyDestinations`.
    @discardableResult
    public func createDestination(
        repositoryID: RepoID?,
        target: DestinationTargetModel,
        stage: String?,
        subscription: KeyVaultSubscriptionModel? = nil
    ) throws(ConfigRepositoryError) -> DestinationID {
        let validTarget = try performConfig { try DestinationRules.validate(target) }
        let validStage = try Self.validStage(stage)
        let limit = repositoryID == nil ? Limits.maxStandaloneKeyVaults : Limits.maxDestinationsPerRepository
        let id = try write { _, tx, now in
            if let repositoryID, try RepoStore(database: session.database).fetch(id: repositoryID, in: tx) == nil {
                throw ConfigRepositoryError.repositoryNotFound
            }
            guard try store.countDestinations(repositoryID: repositoryID, in: tx) < limit else {
                throw ConfigRepositoryError.tooManyDestinations(limit: limit)
            }
            let existing = try store.fetchDestinationRecords(repositoryID: repositoryID, in: tx)
            guard !existing.contains(where: { $0.targetKey == validTarget.targetKey }) else {
                throw ConfigRepositoryError.destinationExists
            }
            let record = DestinationRecord(
                repositoryID: repositoryID,
                target: validTarget,
                stage: validStage,
                sortOrder: try store.nextSortOrder(repositoryID: repositoryID, in: tx),
                subscription: subscription.flatMap(Self.validSubscription),
                createdAt: now,
                updatedAt: now
            )
            try store.insertDestination(record, in: tx)
            return record.id
        }
        Self.log.info("Added a \(validTarget.provider.rawValue, privacy: .public) destination")
        return id
    }

    /// Changes a destination's stage. The target itself never changes: add another destination
    /// instead.
    public func updateDestination(_ id: DestinationID, stage: String?) throws(ConfigRepositoryError) {
        let validStage = try Self.validStage(stage)
        try write { _, tx, now in
            guard var record = try store.fetchDestination(id: id, in: tx) else { throw ConfigRepositoryError.destinationNotFound }
            record.setStage(validStage)
            record.updatedAt = now
            try store.updateDestination(record, in: tx)
        }
    }

    /// Saves the Azure subscription a Key Vault of its own was found in (1.0 D6c6: Connect Azure,
    /// Refresh), so the sidebar groups it under that subscription. A name that is empty or longer
    /// than 255 characters is not saved.
    public func setSubscription(_ subscription: KeyVaultSubscriptionModel, of id: DestinationID) throws(ConfigRepositoryError) {
        guard let valid = Self.validSubscription(subscription) else { return }
        try write { _, tx, now in
            guard var record = try store.fetchDestination(id: id, in: tx) else { throw ConfigRepositoryError.destinationNotFound }
            guard record.subscription != valid else { return }
            record.setSubscription(valid)
            record.updatedAt = now
            try store.updateDestination(record, in: tx)
        }
    }

    /// Cleaned as `az`'s names are (no bidi controls or invisible characters), whoever passes
    /// it: a stored name is shown in the sidebar and Settings.
    private static func validSubscription(_ subscription: KeyVaultSubscriptionModel) -> KeyVaultSubscriptionModel? {
        // No byte cut here: a name over the limit is refused, not shortened.
        let name = DisplayNameSanitizer.sanitize(subscription.name, maxBytes: .max)
        guard (1...Limits.maxSubscriptionNameLength).contains(name.unicodeScalars.count) else { return nil }
        return KeyVaultSubscriptionModel(id: subscription.id, name: name)
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

    /// The destinations of a repository with their counts; nil: the Key Vaults of their own.
    public func destinations(repositoryID: RepoID?) throws(ConfigRepositoryError) -> [DestinationModel] {
        try performConfig { try store.fetchDestinations(repositoryID: repositoryID) }
    }

    /// The Supabase and Vercel destinations migration v16 deleted (1.0), for a notice after
    /// unlock. Empty once ``dismissRetiredDestinations()`` ran.
    public func retiredDestinationLabels() throws(ConfigRepositoryError) -> [String] {
        try performConfig { try store.fetchRetiredDestinationLabels() }
    }

    /// The notice was read: it never shows again.
    public func dismissRetiredDestinations() throws(ConfigRepositoryError) {
        try performConfig { try store.deleteRetiredDestinations() }
    }

    /// The stages Add Destination suggests: the destinations' stages, then the GitHub
    /// environments, once per fold key.
    public func stageSuggestions(repositoryID: RepoID) throws(ConfigRepositoryError) -> [String] {
        try performConfig {
            var seen: Set<String> = []
            let environments = try ConfigStore(database: session.database).fetchEnvironments(repositoryID: repositoryID)
            let stages = try store.fetchDestinations(repositoryID: repositoryID).compactMap(\.stage)
                + environments.filter { !$0.isDeleted }.map(\.name)
            return stages.filter { seen.insert(EnvironmentNameValidator.foldKey($0)).inserted }
        }
    }

    /// The destinations of a repository, now and after each change; nil: the Key Vaults of their own.
    public func observeDestinations(repositoryID: RepoID?) -> AsyncThrowingStream<[DestinationModel], any Error> {
        store.observeDestinations(repositoryID: repositoryID)
    }

    /// Pending destination changes per repository (added to the Sync badge); nil: the Key Vaults
    /// of their own.
    public func observePendingCounts() -> AsyncThrowingStream<[RepoID?: Int], any Error> {
        store.observePendingCounts()
    }

    /// Pending destination changes per repository; nil: the Key Vaults of their own.
    public func pendingCounts() throws(ConfigRepositoryError) -> [RepoID?: Int] {
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
        value: SecretBytes,
        file: FileSecretModel? = nil
    ) throws(ConfigRepositoryError) -> ItemWriteResultModel {
        let normalized = try Self.normalize(value)
        defer { normalized.value.wipe() }
        let id = try write { keys, tx, now in
            try writer(keys, tx, now).add(destinationID: destinationID, kind: kind, name: name, value: normalized.value, file: file)
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

    /// Saves the notes' edits of a destination (1.0 N2) in one transaction; nothing is written
    /// when one fails. They stay pending until the next Sync.
    public func applyEdits(_ edits: PlaceItemEditsModel, destinationID: DestinationID) throws(ConfigRepositoryError) {
        let normalized = try edits.normalized()
        defer { normalized.wipe() }
        try write { keys, tx, now in
            let writer = writer(keys, tx, now)
            _ = try writer.requireDestination(destinationID)
            func requireInDestination(_ id: ConfigItemID) throws -> DestinationItemRecord {
                let record = try writer.existing(id)
                guard record.destinationID == destinationID, !record.isDeleted else {
                    throw ConfigRepositoryError.itemNotFound
                }
                return record
            }
            for id in normalized.deletions {
                _ = try requireInDestination(id)
                try writer.delete(id)
            }
            for change in normalized.changes {
                let current = try requireInDestination(change.id)
                var holder = change.id
                if let name = change.name {
                    holder = try writer.update(change.id, name: name, kind: current.kind)
                }
                if let value = change.value {
                    try writer.editValue(holder, value: value)
                }
            }
            for addition in normalized.additions {
                try writer.add(destinationID: destinationID, kind: addition.kind, name: addition.name, value: addition.value)
            }
        }
        Self.log.info("Saved \(edits.count, privacy: .public) destination edits from the notes")
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
                        try writer.editValue(existing.id, value: value, file: source.file)
                        copyID = existing.id
                        result.replaced += 1
                    }
                } else {
                    copyID = try writer.add(destinationID: destinationID, kind: source.kind, name: source.name, value: value, file: source.file)
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

    // MARK: - Private

    private static let log = Logger(subsystem: ConfigConstants.logSubsystem, category: "destinations")

    static func validStage(_ stage: String?) throws(ConfigRepositoryError) -> String? {
        guard let stage, !stage.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try performConfig { try EnvironmentNameValidator.validate(stage) }
    }

    private static func normalize(_ value: SecretBytes) throws(ConfigRepositoryError) -> ValueNormalizer.NormalizedValue {
        do {
            return try ValueNormalizer.normalize(value)
        } catch {
            throw .validation(error)
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
