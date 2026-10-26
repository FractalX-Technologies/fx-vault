import Foundation
import GRDB
import VaultCore

/// Environments, config items and deployment branch patterns (§6 `v3_config`,
/// `v5_create_policies`, `v6_sharing`, `v9_item_links`).
///
/// Integrity checks beyond the schema:
/// - an item or pattern must belong to an environment of the same repository
///   (``StoreError/scopeMismatch``);
/// - a synced item's kind and scope never change (D11, ``StoreError/immutableAfterSync``).
///
/// Tombstones are ordinary rows with `isDeleted = true`, written with the update methods. The
/// `delete…` methods remove rows (coalescing, "Accept GitHub" deletions, after a verified remote
/// delete).
public struct ConfigStore: Sendable {
    public let database: VaultDatabase

    public init(database: VaultDatabase) {
        self.database = database
    }

    // MARK: - Environments

    /// The repository's environments (tombstones included), ordered by `sort_order` then name,
    /// with the pattern rows of custom policies attached.
    public func fetchEnvironments(repositoryID: RepoID) throws -> [EnvironmentModel] {
        try database.read { try fetchEnvironments(repositoryID: repositoryID, in: $0) }
    }

    public func fetchEnvironments(repositoryID: RepoID, in tx: StoreTransaction) throws -> [EnvironmentModel] {
        try Self.environments(repositoryID: repositoryID, db: tx.db)
    }

    /// Every repository's environments (tombstones included) in one query, in the order of
    /// ``fetchEnvironments(repositoryID:)`` within each repository.
    public func fetchAllEnvironments() throws -> [EnvironmentModel] {
        try database.read { tx in
            try Self.attachPatterns(to: try Self.orderedEnvironments.fetchAll(tx.db), db: tx.db)
        }
    }

    public func fetchEnvironment(id: EnvironmentID) throws -> EnvironmentModel? {
        try database.read { try fetchEnvironment(id: id, in: $0) }
    }

    public func fetchEnvironment(id: EnvironmentID, in tx: StoreTransaction) throws -> EnvironmentModel? {
        guard let record = try EnvironmentRecord.fetchOne(tx.db, key: id.uuidString) else {
            return nil
        }
        return try Self.attachPatterns(to: [record], db: tx.db).first
    }

    /// Inserts the environment and, for a custom policy, its pattern rows. Throws
    /// ``StoreError/constraintViolation(_:)`` (`.unique`) when another environment of the
    /// repository has the same fold key.
    public func insertEnvironment(_ environment: EnvironmentModel) throws {
        try database.write { try insertEnvironment(environment, in: $0) }
    }

    public func insertEnvironment(_ environment: EnvironmentModel, in tx: StoreTransaction) throws {
        try EnvironmentRecord(environment).insert(tx.db)
        for pattern in environment.branchPolicy.patterns {
            guard pattern.environmentID == environment.id else {
                throw StoreError.scopeMismatch
            }
            try BranchPatternRecord(pattern).insert(tx.db)
        }
    }

    /// Replaces the environment row (name, policy kind, sync columns, tombstone flag). Pattern
    /// rows are not touched: use the pattern methods. Throws ``StoreError/notFound`` if there is
    /// no such row.
    public func updateEnvironment(_ environment: EnvironmentModel) throws {
        try database.write { try updateEnvironment(environment, in: $0) }
    }

    public func updateEnvironment(_ environment: EnvironmentModel, in tx: StoreTransaction) throws {
        do {
            try EnvironmentRecord(environment).update(tx.db)
        } catch is RecordError {
            throw StoreError.notFound
        }
    }

    /// Removes the environment row and, by cascade, its items and patterns. Returns false if
    /// there was none.
    @discardableResult
    public func deleteEnvironment(id: EnvironmentID) throws -> Bool {
        try database.write { try deleteEnvironment(id: id, in: $0) }
    }

    @discardableResult
    public func deleteEnvironment(id: EnvironmentID, in tx: StoreTransaction) throws -> Bool {
        try EnvironmentRecord.deleteOne(tx.db, key: id.uuidString)
    }

    /// The repository's environments, now and after each change.
    public func observeEnvironments(repositoryID: RepoID) -> AsyncThrowingStream<[EnvironmentModel], any Error> {
        database.observe { db in
            try Self.environments(repositoryID: repositoryID, db: db)
        }
    }

    // MARK: - Branch patterns

    /// The environment's pattern rows (tombstones included), ordered by type then pattern.
    public func fetchPatterns(environmentID: EnvironmentID) throws -> [BranchPatternModel] {
        try database.read { try fetchPatterns(environmentID: environmentID, in: $0) }
    }

    public func fetchPatterns(environmentID: EnvironmentID, in tx: StoreTransaction) throws -> [BranchPatternModel] {
        try Self.orderedPatterns
            .filter(BranchPatternRecord.CodingKeys.environmentID == environmentID.uuidString)
            .fetchAll(tx.db)
            .map(\.model)
    }

    /// Inserts a pattern row. Throws ``StoreError/constraintViolation(_:)`` (`.unique`) for a
    /// duplicate `(pattern, type)` in the environment.
    public func insertPattern(_ pattern: BranchPatternModel) throws {
        try database.write { try insertPattern(pattern, in: $0) }
    }

    public func insertPattern(_ pattern: BranchPatternModel, in tx: StoreTransaction) throws {
        try BranchPatternRecord(pattern).insert(tx.db)
    }

    /// Replaces a pattern row. Throws ``StoreError/notFound`` if there is none, and
    /// ``StoreError/scopeMismatch`` if it would move to another environment.
    public func updatePattern(_ pattern: BranchPatternModel) throws {
        try database.write { try updatePattern(pattern, in: $0) }
    }

    public func updatePattern(_ pattern: BranchPatternModel, in tx: StoreTransaction) throws {
        guard let existing = try BranchPatternRecord.fetchOne(tx.db, key: pattern.id.uuidString) else {
            throw StoreError.notFound
        }
        guard existing.environmentID == pattern.environmentID else {
            throw StoreError.scopeMismatch
        }
        try BranchPatternRecord(pattern).update(tx.db)
    }

    @discardableResult
    public func deletePattern(id: BranchPatternID) throws -> Bool {
        try database.write { try deletePattern(id: id, in: $0) }
    }

    @discardableResult
    public func deletePattern(id: BranchPatternID, in tx: StoreTransaction) throws -> Bool {
        try BranchPatternRecord.deleteOne(tx.db, key: id.uuidString)
    }

    /// Sets `github_policy_id = NULL` on every pattern of the environment (its policy left
    /// custom on GitHub, §7.3 step 2). Returns the number of rows changed.
    @discardableResult
    public func clearPatternPolicyIDs(environmentID: EnvironmentID) throws -> Int {
        try database.write { try clearPatternPolicyIDs(environmentID: environmentID, in: $0) }
    }

    @discardableResult
    public func clearPatternPolicyIDs(environmentID: EnvironmentID, in tx: StoreTransaction) throws -> Int {
        try BranchPatternRecord
            .filter(BranchPatternRecord.CodingKeys.environmentID == environmentID.uuidString)
            .filter(BranchPatternRecord.CodingKeys.githubPolicyID != nil)
            .updateAll(tx.db, BranchPatternRecord.CodingKeys.githubPolicyID.set(to: nil))
    }

    // MARK: - Items: full records (ciphertext)

    /// The full row, ciphertexts included, or nil.
    public func fetchItemRecord(id: ConfigItemID) throws -> ConfigItemRecord? {
        try database.read { try fetchItemRecord(id: id, in: $0) }
    }

    public func fetchItemRecord(id: ConfigItemID, in tx: StoreTransaction) throws -> ConfigItemRecord? {
        try ConfigItemRecord.fetchOne(tx.db, key: id.uuidString)
    }

    /// Full rows of one repository, optionally narrowed to one scope, ordered by name then kind.
    /// For export and duplication; lists use ``fetchItems(repositoryID:scope:)``.
    public func fetchItemRecords(repositoryID: RepoID, scope: ConfigScope? = nil) throws -> [ConfigItemRecord] {
        try database.read { try fetchItemRecords(repositoryID: repositoryID, scope: scope, in: $0) }
    }

    public func fetchItemRecords(
        repositoryID: RepoID,
        scope: ConfigScope? = nil,
        in tx: StoreTransaction
    ) throws -> [ConfigItemRecord] {
        try Self.itemFilter(ConfigItemRecord.all(), repositoryID: repositoryID, scope: scope)
            .order(ConfigItemRecord.CodingKeys.name, ConfigItemRecord.CodingKeys.kind)
            .fetchAll(tx.db)
    }

    /// Ids of every item, or of one repository's items, in a stable order. Long jobs (DEK
    /// rotation) fetch and rewrite one record at a time from this list.
    public func fetchItemIDs(repositoryID: RepoID? = nil) throws -> [ConfigItemID] {
        try database.read { tx in
            var request = ConfigItemRecord.select(ConfigItemRecord.CodingKeys.id, as: String.self)
            if let repositoryID {
                request = request.filter(ConfigItemRecord.CodingKeys.repositoryID == repositoryID.uuidString)
            }
            return try request
                .order(ConfigItemRecord.CodingKeys.id)
                .fetchAll(tx.db)
                .compactMap { ConfigItemID(uuidString: $0) }
        }
    }

    /// Inserts an item. Throws ``StoreError/scopeMismatch`` when its environment belongs to
    /// another repository, and ``StoreError/constraintViolation(_:)`` for a duplicate name in the
    /// scope (`.unique`) or an invalid row (`.check`: lowercase name, a variable without a value,
    /// `value_ct` without `value_fp`).
    public func insertItem(_ item: ConfigItemRecord) throws {
        try database.write { try insertItem(item, in: $0) }
    }

    public func insertItem(_ item: ConfigItemRecord, in tx: StoreTransaction) throws {
        try Self.checkScope(repositoryID: item.repositoryID, environmentID: item.environmentID, db: tx.db)
        try item.insert(tx.db)
    }

    /// Replaces an item row. Throws ``StoreError/notFound`` if there is none, and
    /// ``StoreError/immutableAfterSync`` if the stored row is synced and `item` changes its
    /// repository, scope or kind (D11).
    public func updateItem(_ item: ConfigItemRecord) throws {
        try database.write { try updateItem(item, in: $0) }
    }

    public func updateItem(_ item: ConfigItemRecord, in tx: StoreTransaction) throws {
        guard let existing = try ConfigItemRecord.fetchOne(tx.db, key: item.id.uuidString) else {
            throw StoreError.notFound
        }
        let movesOrConverts = existing.repositoryID != item.repositoryID
            || existing.environmentID != item.environmentID
            || existing.kind != item.kind
        if movesOrConverts {
            guard existing.syncedName == nil else {
                throw StoreError.immutableAfterSync
            }
            try Self.checkScope(repositoryID: item.repositoryID, environmentID: item.environmentID, db: tx.db)
        }
        try item.update(tx.db)
    }

    /// Removes an item row. Returns false if there was none.
    @discardableResult
    public func deleteItem(id: ConfigItemID) throws -> Bool {
        try database.write { try deleteItem(id: id, in: $0) }
    }

    @discardableResult
    public func deleteItem(id: ConfigItemID, in tx: StoreTransaction) throws -> Bool {
        try ConfigItemRecord.deleteOne(tx.db, key: id.uuidString)
    }

    // MARK: - Items: states and models (no ciphertext)

    /// Item states of one repository, optionally one scope, ordered by name then kind.
    public func fetchItemStates(repositoryID: RepoID, scope: ConfigScope? = nil) throws -> [ConfigItemState] {
        try database.read { try fetchItemStates(repositoryID: repositoryID, scope: scope, in: $0) }
    }

    public func fetchItemStates(
        repositoryID: RepoID,
        scope: ConfigScope? = nil,
        in tx: StoreTransaction
    ) throws -> [ConfigItemState] {
        try Self.itemStates(repositoryID: repositoryID, scope: scope, db: tx.db)
    }

    /// Item models (status derived) of one repository, optionally one scope, ordered by name then
    /// kind. Tombstones are included (status `.deleted`).
    public func fetchItems(repositoryID: RepoID, scope: ConfigScope? = nil) throws -> [ConfigItemModel] {
        try fetchItemStates(repositoryID: repositoryID, scope: scope).map(\.model)
    }

    /// Items of one kind at one scope that count toward GitHub's limit (tombstones excluded),
    /// for ``ScopeCapacityValidator``.
    public func countActiveItems(repositoryID: RepoID, scope: ConfigScope, kind: ConfigKind) throws -> Int {
        try database.read { tx in
            try Self.itemFilter(ConfigItemRecord.all(), repositoryID: repositoryID, scope: scope)
                .filter(ConfigItemRecord.CodingKeys.kind == kind.rawValue)
                .filter(ConfigItemRecord.CodingKeys.isDeleted == false)
                .fetchCount(tx.db)
        }
    }

    /// Item models of one repository (optionally one scope), now and after each change, each with
    /// its ``ConfigItemModel/linkCount`` (v0.4.1).
    public func observeItems(
        repositoryID: RepoID,
        scope: ConfigScope? = nil
    ) -> AsyncThrowingStream<[ConfigItemModel], any Error> {
        database.observe { db in
            let states = try Self.itemStates(repositoryID: repositoryID, scope: scope, db: db)
            let counts = try Self.linkCounts(of: states, db: db)
            return states.map { state in
                var model = state.model
                model.linkCount = state.linkID.flatMap { counts[$0] } ?? 0
                return model
            }
        }
    }

    // MARK: - Linked copies (v0.4.1)

    /// The live rows (tombstones excluded) of one link group in every repository, ciphertexts
    /// included, ordered by repository, scope and name.
    public func fetchLinkedItemRecords(linkID: ItemLinkID, in tx: StoreTransaction) throws -> [ConfigItemRecord] {
        try ConfigItemRecord
            .filter(ConfigItemRecord.CodingKeys.linkID == linkID.uuidString)
            .filter(ConfigItemRecord.CodingKeys.isDeleted == false)
            .order(
                ConfigItemRecord.CodingKeys.repositoryID,
                ConfigItemRecord.CodingKeys.environmentID,
                ConfigItemRecord.CodingKeys.name
            )
            .fetchAll(tx.db)
    }

    /// Sets or clears `link_id` on `itemIDs`. Link metadata only: no other column changes, so the
    /// rows' values, AADs and sync state are untouched.
    public func setLinkID(_ linkID: ItemLinkID?, itemIDs: [ConfigItemID], in tx: StoreTransaction) throws {
        guard !itemIDs.isEmpty else { return }
        try ConfigItemRecord
            .filter(keys: itemIDs.map(\.uuidString))
            .updateAll(tx.db, ConfigItemRecord.CodingKeys.linkID.set(to: linkID?.uuidString))
    }

    /// Live rows per link group of `states`, across every repository and folder (v0.7.0).
    static func linkCounts(of states: [ConfigItemState], db: Database) throws -> [ItemLinkID: Int] {
        try LinkCountQuery.counts(of: Set(states.compactMap(\.linkID)), db: db)
    }

    // MARK: - Share holds (v0.9.0)

    /// Sets or clears `share_hold` on `itemIDs`. Hold metadata only: the rows' values, AADs and
    /// sync state are untouched.
    public func setShareHold(_ packageID: SharePackageID?, itemIDs: [ConfigItemID], in tx: StoreTransaction) throws {
        guard !itemIDs.isEmpty else { return }
        try ConfigItemRecord
            .filter(keys: itemIDs.map(\.uuidString))
            .updateAll(tx.db, ConfigItemRecord.CodingKeys.shareHold.set(to: packageID?.uuidString))
    }

    /// The rows held under `packageID`, or under any share file when nil, without ciphertext,
    /// ordered by repository, scope and name.
    public func fetchHeldItemStates(packageID: SharePackageID? = nil, in tx: StoreTransaction) throws -> [ConfigItemState] {
        var request = ConfigItemRecord.filter(ConfigItemRecord.CodingKeys.shareHold != nil)
        if let packageID {
            request = request.filter(ConfigItemRecord.CodingKeys.shareHold == packageID.uuidString)
        }
        return try request
            .select(ConfigItemState.selection)
            .order(
                ConfigItemRecord.CodingKeys.repositoryID,
                ConfigItemRecord.CodingKeys.environmentID,
                ConfigItemRecord.CodingKeys.name,
                ConfigItemRecord.CodingKeys.kind
            )
            .asRequest(of: ConfigItemState.self)
            .fetchAll(tx.db)
    }

    public func fetchHeldItemStates(packageID: SharePackageID? = nil) throws -> [ConfigItemState] {
        try database.read { try fetchHeldItemStates(packageID: packageID, in: $0) }
    }

    /// Releases every row held under `packageID`. Returns how many rows it released.
    @discardableResult
    public func clearShareHold(packageID: SharePackageID, in tx: StoreTransaction) throws -> Int {
        try ConfigItemRecord
            .filter(ConfigItemRecord.CodingKeys.shareHold == packageID.uuidString)
            .updateAll(tx.db, ConfigItemRecord.CodingKeys.shareHold.set(to: nil))
    }

    // MARK: - Pending-change inputs (§7.1)

    /// Everything `ChangeSetBuilder` needs for one repository, without ciphertext; nil if the
    /// repository does not exist.
    public func fetchPendingInputs(repositoryID: RepoID) throws -> RepoPendingInputsModel? {
        try database.read { try fetchPendingInputs(repositoryID: repositoryID, in: $0) }
    }

    public func fetchPendingInputs(repositoryID: RepoID, in tx: StoreTransaction) throws -> RepoPendingInputsModel? {
        try Self.pendingInputs(repositoryID: repositoryID, db: tx.db)
    }

    /// One repository's pending-change inputs, now and after each change; nil once it is deleted.
    public func observePendingInputs(repositoryID: RepoID) -> AsyncThrowingStream<RepoPendingInputsModel?, any Error> {
        database.observe { db in
            try Self.pendingInputs(repositoryID: repositoryID, db: db)
        }
    }

    /// Pending-change inputs of every repository (toolbar count, Sync all), now and after each
    /// change. Ordered like the sidebar.
    public func observeAllPendingInputs() -> AsyncThrowingStream<[RepoPendingInputsModel], any Error> {
        database.observe { db in
            try Self.allPendingInputs(db: db)
        }
    }

    public func fetchAllPendingInputs() throws -> [RepoPendingInputsModel] {
        try database.read { tx in try Self.allPendingInputs(db: tx.db) }
    }
}

// MARK: - Queries

extension ConfigStore {
    static var orderedEnvironments: QueryInterfaceRequest<EnvironmentRecord> {
        EnvironmentRecord.order(
            EnvironmentRecord.CodingKeys.sortOrder,
            EnvironmentRecord.CodingKeys.nameKey,
            EnvironmentRecord.CodingKeys.id
        )
    }

    static var orderedPatterns: QueryInterfaceRequest<BranchPatternRecord> {
        BranchPatternRecord.order(
            BranchPatternRecord.CodingKeys.type,
            BranchPatternRecord.CodingKeys.pattern
        )
    }

    static func environments(repositoryID: RepoID, db: Database) throws -> [EnvironmentModel] {
        let records = try orderedEnvironments
            .filter(EnvironmentRecord.CodingKeys.repositoryID == repositoryID.uuidString)
            .fetchAll(db)
        return try attachPatterns(to: records, db: db)
    }

    /// Builds models for `records`, loading the pattern rows of all of them in one query.
    static func attachPatterns(to records: [EnvironmentRecord], db: Database) throws -> [EnvironmentModel] {
        let customIDs = records.filter { $0.branchPolicy == .custom }.map(\.id.uuidString)
        var patternsByEnvironment: [EnvironmentID: [BranchPatternModel]] = [:]
        if !customIDs.isEmpty {
            let patterns = try orderedPatterns
                .filter(customIDs.contains(BranchPatternRecord.CodingKeys.environmentID))
                .fetchAll(db)
            for pattern in patterns {
                patternsByEnvironment[pattern.environmentID, default: []].append(pattern.model)
            }
        }
        return records.map { $0.model(patterns: patternsByEnvironment[$0.id] ?? []) }
    }

    static func itemFilter(
        _ request: QueryInterfaceRequest<ConfigItemRecord>,
        repositoryID: RepoID,
        scope: ConfigScope?
    ) -> QueryInterfaceRequest<ConfigItemRecord> {
        var request = request.filter(ConfigItemRecord.CodingKeys.repositoryID == repositoryID.uuidString)
        switch scope {
        case nil:
            break
        case .repository:
            request = request.filter(ConfigItemRecord.CodingKeys.environmentID == nil)
        case .environment(let environmentID):
            request = request.filter(ConfigItemRecord.CodingKeys.environmentID == environmentID.uuidString)
        }
        return request
    }

    static func itemStates(repositoryID: RepoID, scope: ConfigScope?, db: Database) throws -> [ConfigItemState] {
        try itemFilter(ConfigItemRecord.all(), repositoryID: repositoryID, scope: scope)
            .select(ConfigItemState.selection)
            .order(ConfigItemRecord.CodingKeys.name, ConfigItemRecord.CodingKeys.kind)
            .asRequest(of: ConfigItemState.self)
            .fetchAll(db)
    }

    static func pendingInputs(repositoryID: RepoID, db: Database) throws -> RepoPendingInputsModel? {
        guard let repository = try RepositoryRecord.fetchOne(db, key: repositoryID.uuidString) else {
            return nil
        }
        return RepoPendingInputsModel(
            repository: repository.model,
            environments: try environments(repositoryID: repositoryID, db: db),
            items: try itemStates(repositoryID: repositoryID, scope: nil, db: db)
        )
    }

    static func allPendingInputs(db: Database) throws -> [RepoPendingInputsModel] {
        let repositories = try RepoStore.orderedRequest.fetchAll(db)
        let environments = try attachPatterns(to: orderedEnvironments.fetchAll(db), db: db)
        let items = try ConfigItemRecord
            .select(ConfigItemState.selection)
            .order(ConfigItemRecord.CodingKeys.name, ConfigItemRecord.CodingKeys.kind)
            .asRequest(of: ConfigItemState.self)
            .fetchAll(db)
        let environmentsByRepo = Dictionary(grouping: environments, by: \.repositoryID)
        let itemsByRepo = Dictionary(grouping: items, by: \.repositoryID)
        return repositories.map { repository in
            RepoPendingInputsModel(
                repository: repository.model,
                environments: environmentsByRepo[repository.id] ?? [],
                items: itemsByRepo[repository.id] ?? []
            )
        }
    }

    /// An environment-scoped row must point at an environment of the same repository. A missing
    /// environment is left to the foreign key.
    static func checkScope(repositoryID: RepoID, environmentID: EnvironmentID?, db: Database) throws {
        guard let environmentID else { return }
        let owner = try EnvironmentRecord
            .select(EnvironmentRecord.CodingKeys.repositoryID, as: String.self)
            .filter(key: environmentID.uuidString)
            .fetchOne(db)
        if let owner, owner != repositoryID.uuidString {
            throw StoreError.scopeMismatch
        }
    }
}

/// Everything the pure change derivation (§7.1 `ChangeSetBuilder`) needs for one repository:
/// the repository, its environments with their pattern rows, and its item states. Carries no
/// ciphertext.
public struct RepoPendingInputsModel: Sendable, Hashable {
    public var repository: RepoModel
    /// Ordered by `sort_order` then name; tombstones included.
    public var environments: [EnvironmentModel]
    /// Ordered by name then kind; tombstones included.
    public var items: [ConfigItemState]

    public init(repository: RepoModel, environments: [EnvironmentModel], items: [ConfigItemState]) {
        self.repository = repository
        self.environments = environments
        self.items = items
    }
}
