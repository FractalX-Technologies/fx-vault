import Foundation
import SyncEngine
import VaultCore
import VaultStore

/// Environment rows of one repository inside the caller's transaction (§7.1 editing rules,
/// §7.6, D20).
///
/// Names are NFC and unique by fold key. A new or renamed environment may not take another
/// row's `name_key`, nor the `synced_name_key` of a row with a pending rename or deletion.
/// Creating an environment whose key belongs to a tombstone revives the tombstone (delete then
/// re-create = undo), so its synced items come back with it.
struct EnvironmentEditor {
    let store: ConfigStore
    let tx: StoreTransaction
    let now: Date
    let writePolicy: WriteCollaboratorPolicy

    // MARK: - Loading

    /// The repository and its environments; throws `repositoryNotFound`.
    func load(_ repositoryID: RepoID) throws -> RepoSnapshotModel {
        guard let inputs = try store.fetchPendingInputs(repositoryID: repositoryID, in: tx) else {
            throw ConfigRepositoryError.repositoryNotFound
        }
        return RepoSnapshotMapper.snapshot(inputs)
    }

    /// The environment and its repository snapshot; throws `environmentNotFound`.
    func load(environment id: EnvironmentID) throws -> (EnvironmentModel, RepoSnapshotModel) {
        guard let environment = try store.fetchEnvironment(id: id, in: tx) else {
            throw ConfigRepositoryError.environmentNotFound
        }
        return (environment, try load(environment.repositoryID))
    }

    /// Throws unless the viewer may change environments of `repository`.
    func requireEditable(_ repository: RepoModel) throws {
        if let reason = repository.capability(writePolicy: writePolicy).readOnlyReason(for: .environment) {
            throw ConfigRepositoryError.readOnly(reason)
        }
    }

    // MARK: - Create

    /// Creates `name` with `policy` (or revives the tombstone holding its key).
    func create(in repositoryID: RepoID, name: String, policy: BranchPolicyDraftModel) throws -> EnvironmentID {
        let snapshot = try load(repositoryID)
        try requireEditable(snapshot.repository)
        let name = try Self.validated(name)
        let patterns = try policy.validatedPatterns()
        let key = EnvironmentNameValidator.foldKey(name)
        if var tombstone = snapshot.environments.first(where: { $0.isDeleted && $0.nameKey == key }) {
            tombstone.isDeleted = false
            tombstone.name = name
            tombstone.branchPolicy = Self.policyKind(policy, patterns: tombstone.branchPolicy.patterns)
            tombstone.updatedAt = now
            try store.updateEnvironment(tombstone, in: tx)
            if case .custom = policy {
                try reconcilePatterns(of: tombstone.id, desired: patterns)
            }
            return tombstone.id
        }
        let keys = snapshot.environmentNameKeys()
        try Self.checkAvailability(name, keys: keys)
        let id = EnvironmentID()
        let sortOrder = (snapshot.environments.map(\.sortOrder).max() ?? -1) + 1
        let rows = patterns.map { BranchPatternModel(environmentID: id, pattern: $0.pattern, type: $0.type) }
        let environment = EnvironmentModel(
            id: id,
            repositoryID: repositoryID,
            name: name,
            branchPolicy: Self.policyKind(policy, patterns: rows),
            sortOrder: sortOrder,
            createdAt: now,
            updatedAt: now
        )
        try store.insertEnvironment(environment, in: tx)
        return id
    }

    // MARK: - Rename

    /// Renames the environment locally (§7.1, D20).
    func rename(_ id: EnvironmentID, to name: String) throws -> EnvironmentRenameKind {
        let (environment, snapshot) = try load(environment: id)
        try requireEditable(snapshot.repository)
        guard !environment.isDeleted else { throw ConfigRepositoryError.environmentDeleted }
        let name = try Self.validated(name)
        guard name != environment.name else { return .unchanged }
        let key = EnvironmentNameValidator.foldKey(name)
        if key != environment.nameKey {
            try Self.checkAvailability(name, keys: snapshot.environmentNameKeys(excluding: id))
        }
        var renamed = environment
        renamed.name = name
        renamed.updatedAt = now
        try store.updateEnvironment(renamed, in: tx)
        guard renamed.isSynced else { return .local }
        if renamed.hasPendingRename { return .recreateOnGitHub }
        return renamed.hasCaseOnlyRename ? .caseOnly : .local
    }

    // MARK: - Delete

    /// Deletes the environment: a never-synced one is removed with its items and patterns; a
    /// synced one becomes a tombstone under its synced name (its items are deleted with it on
    /// GitHub, §7.1).
    func delete(_ id: EnvironmentID) throws {
        let (environment, snapshot) = try load(environment: id)
        try requireEditable(snapshot.repository)
        guard !environment.isDeleted else { return }
        guard let syncedName = environment.syncedName else {
            try store.deleteEnvironment(id: id, in: tx)
            return
        }
        var tombstone = environment
        tombstone.isDeleted = true
        tombstone.name = syncedName
        tombstone.updatedAt = now
        try store.updateEnvironment(tombstone, in: tx)
    }

    // MARK: - Policy

    /// Sets the desired branch policy (§10 `BranchPolicyEditor`).
    func updatePolicy(_ id: EnvironmentID, to policy: BranchPolicyDraftModel) throws {
        let (environment, snapshot) = try load(environment: id)
        try requireEditable(snapshot.repository)
        guard !environment.isDeleted else { throw ConfigRepositoryError.environmentDeleted }
        let patterns = try policy.validatedPatterns()
        var updated = environment
        updated.branchPolicy = Self.policyKind(policy, patterns: environment.branchPolicy.patterns)
        updated.updatedAt = now
        try store.updateEnvironment(updated, in: tx)
        if case .custom = policy {
            try reconcilePatterns(of: id, desired: patterns)
        }
    }

    /// Maps `desired` onto the pattern rows: existing rows are kept (a tombstone is revived),
    /// new ones inserted unsynced, and rows no longer wanted become tombstones when GitHub has
    /// them or are deleted otherwise.
    private func reconcilePatterns(of id: EnvironmentID, desired: [BranchPatternDraftModel]) throws {
        let rows = try store.fetchPatterns(environmentID: id, in: tx)
        let wanted = Set(desired)
        for row in rows {
            let draft = BranchPatternDraftModel(pattern: row.pattern, type: row.type)
            if wanted.contains(draft) {
                if row.isDeleted {
                    var revived = row
                    revived.isDeleted = false
                    try store.updatePattern(revived, in: tx)
                }
            } else if row.isSynced {
                if !row.isDeleted {
                    var tombstone = row
                    tombstone.isDeleted = true
                    try store.updatePattern(tombstone, in: tx)
                }
            } else {
                try store.deletePattern(id: row.id, in: tx)
            }
        }
        let existing = Set(rows.map { BranchPatternDraftModel(pattern: $0.pattern, type: $0.type) })
        for draft in desired where !existing.contains(draft) {
            try store.insertPattern(BranchPatternModel(environmentID: id, pattern: draft.pattern, type: draft.type), in: tx)
        }
    }

    // MARK: - Revert

    /// Drops every local change of the environment (§7.1 Revert, Discard all): a never-synced
    /// environment is removed with its items; a synced one gets back its synced name and policy,
    /// unsynced patterns are deleted and deleted synced patterns restored. Items are reverted
    /// separately.
    func revert(_ id: EnvironmentID) throws {
        guard let environment = try store.fetchEnvironment(id: id, in: tx) else {
            throw ConfigRepositoryError.environmentNotFound
        }
        guard let syncedName = environment.syncedName else {
            try store.deleteEnvironment(id: id, in: tx)
            return
        }
        var reverted = environment
        reverted.isDeleted = false
        reverted.name = syncedName
        let rows = try store.fetchPatterns(environmentID: id, in: tx)
        for row in rows {
            if !row.isSynced {
                try store.deletePattern(id: row.id, in: tx)
            } else if row.isDeleted {
                var restored = row
                restored.isDeleted = false
                try store.updatePattern(restored, in: tx)
            }
        }
        let syncedRows = rows.filter(\.isSynced).map { row in
            var restored = row
            restored.isDeleted = false
            return restored
        }
        reverted.branchPolicy = switch environment.syncedBranchPolicy ?? .all {
        case .all: .all
        case .protected: .protectedBranches
        case .custom: .custom(syncedRows)
        }
        if reverted != environment {
            reverted.updatedAt = now
            try store.updateEnvironment(reverted, in: tx)
        }
    }

    /// True when the environment has a local change of its own (not counting its items).
    static func hasPendingChange(_ environment: EnvironmentModel) -> Bool {
        if environment.isDeleted { return environment.isSynced }
        guard environment.isSynced else { return true }
        if environment.hasPendingRename || environment.hasCaseOnlyRename || environment.hasPendingPolicyChange {
            return true
        }
        guard case .custom(let patterns) = environment.branchPolicy else { return false }
        return patterns.contains { $0.isDeleted ? $0.isSynced : !$0.isSynced }
    }

    // MARK: - Helpers

    static func validated(_ name: String) throws -> String {
        do {
            return try EnvironmentNameValidator.validate(name)
        } catch {
            throw ConfigRepositoryError.validation(error)
        }
    }

    static func checkAvailability(_ name: String, keys: (taken: Set<String>, reserved: Set<String>)) throws {
        do {
            try EnvironmentNameValidator.checkAvailability(of: name, takenKeys: keys.taken, reservedKeys: keys.reserved)
        } catch {
            throw ConfigRepositoryError.validation(error)
        }
    }

    /// The model policy for `draft`; for custom, `patterns` are attached (only the kind is
    /// written to the environment row).
    static func policyKind(_ draft: BranchPolicyDraftModel, patterns: [BranchPatternModel]) -> DeploymentBranchPolicyModel {
        switch draft {
        case .all: .all
        case .protectedBranches: .protectedBranches
        case .custom: .custom(patterns)
        }
    }
}
