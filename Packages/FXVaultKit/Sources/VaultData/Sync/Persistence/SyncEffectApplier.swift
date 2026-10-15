import Foundation
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// Applies SyncEngine's `SyncStateEffectModel`s to the vault rows inside one transaction
/// (§7.3, §7.4, §7.6), with exactly the semantics documented on each effect. SyncEngine's
/// `InMemorySyncVault` is the reference; `VaultSyncPersistenceTests` checks this applier
/// against the same scenarios.
///
/// Only ``SyncStateEffectModel/itemPushed(_:)`` needs keys (it re-seals the pushed value as the
/// synced value, and a rename's detached tombstone); every other effect is plain bookkeeping and
/// can be recorded while the vault is locked.
struct SyncEffectApplier {
    let rows: SyncRowWriter
    /// Nil when no effect of the commit needs keys.
    let keys: UnlockedKeys?

    /// True when `effect` decrypts or seals a value.
    static func needsKeys(_ effect: SyncStateEffectModel) -> Bool {
        if case .itemPushed = effect { return true }
        return false
    }

    func apply(_ effect: SyncStateEffectModel) throws {
        switch effect {
        case .repositoryCreated(let created):
            try rows.updateRepository(created.repositoryID) { repository in
                repository.githubID = created.githubID
                repository.ownerLogin = created.ownerLogin
                repository.name = created.name
                repository.visibility = created.visibility
                repository.defaultBranch = created.defaultBranch
                repository.hasAdmin = created.hasAdmin
                repository.hasPush = created.hasPush
                repository.createdAtGitHub = created.createdAt
            }
        case .repositoryPlanGated(let repositoryID):
            try rows.updateRepository(repositoryID) { $0.isEnvPlanGated = true }
        case .environmentSynced(let synced):
            try rows.updateEnvironment(synced.environmentID) { Self.apply(synced, to: &$0) }
        case .environmentRenamed(let renamed):
            try applyRename(renamed)
        case .environmentDeleted(let environmentID):
            try rows.config.deleteEnvironment(id: environmentID, in: rows.tx)
        case .patternsUnsynced(let environmentID):
            try rows.unsyncPatterns(of: environmentID)
        case .patternSynced(let environmentID, let patternID, let githubPolicyID):
            try syncPattern(patternID, of: environmentID, githubPolicyID: githubPolicyID)
        case .patternRemoved(_, let patternID):
            try rows.config.deletePattern(id: patternID, in: rows.tx)
        case .itemPreWriteBaseline(let itemID, let updatedAt):
            try rows.updateItem(itemID) { $0.preWriteUpdatedAt = updatedAt }
        case .itemPushed(let pushed):
            guard let keys else { throw VaultError.locked }
            try applyPush(pushed, keys: keys)
        case .itemVerified(let itemID, let remoteUpdatedAt):
            try rows.updateItem(itemID) { record in
                record.verifyState = .verified
                record.remoteUpdatedAt = remoteUpdatedAt
                if record.provenance == .share {
                    record.provenance = .local
                    record.shareOrigin = nil
                }
            }
        case .itemVerificationExpired(let itemID, let forcePush):
            try rows.updateItem(itemID) { record in
                record.verifyState = .verified
                if forcePush { record.forcePush = true }
            }
        case .itemDeleted(let deleted):
            try applyDelete(deleted)
        }
    }

    // MARK: - Environments

    static func apply(_ synced: EnvironmentSyncedEffectModel, to environment: inout EnvironmentModel) {
        environment.syncedName = synced.syncedName
        environment.githubEnvID = synced.githubID
        environment.syncedBranchPolicy = synced.policy
        environment.foreignRulesJSON = synced.foreignRulesJSON
        environment.remoteUpdatedAt = synced.remoteUpdatedAt
    }

    /// §7.6 step 5: the row moves to its new remote identity and a new tombstone row (no
    /// children) holds the previous one, so the old environment's DELETE is an ordinary pending
    /// deletion.
    private func applyRename(_ renamed: EnvironmentRenamedEffectModel) throws {
        guard let environment = try rows.config.fetchEnvironment(id: renamed.synced.environmentID, in: rows.tx) else {
            return
        }
        var moved = environment
        Self.apply(renamed.synced, to: &moved)
        try rows.config.updateEnvironment(moved, in: rows.tx)

        let previousKey = EnvironmentNameValidator.foldKey(renamed.previousName)
        let siblings = try rows.config.fetchEnvironments(repositoryID: environment.repositoryID, in: rows.tx)
        // A row already holding the previous name (an earlier tombstone) keeps the identity.
        guard !siblings.contains(where: { $0.nameKey == previousKey }) else { return }
        let previousPolicy: DeploymentBranchPolicyModel = switch renamed.previousPolicy {
        case .protected: .protectedBranches
        case .custom: .custom([])
        case .all, nil: .all
        }
        try rows.config.insertEnvironment(
            EnvironmentModel(
                repositoryID: environment.repositoryID,
                name: renamed.previousName,
                syncedName: renamed.previousName,
                isDeleted: true,
                branchPolicy: previousPolicy,
                syncedBranchPolicy: renamed.previousPolicy,
                githubEnvID: renamed.previousGitHubID,
                sortOrder: environment.sortOrder,
                createdAt: rows.now,
                updatedAt: rows.now
            ),
            in: rows.tx
        )
    }

    private func syncPattern(_ patternID: BranchPatternID, of environmentID: EnvironmentID, githubPolicyID: Int64) throws {
        let patterns = try rows.config.fetchPatterns(environmentID: environmentID, in: rows.tx)
        guard var pattern = patterns.first(where: { $0.id == patternID }) else { return }
        pattern.githubPolicyID = githubPolicyID
        try rows.config.updatePattern(pattern, in: rows.tx)
    }

    // MARK: - Items

    /// A successful C5/C7 (`ItemPushedEffectModel` documents the three steps).
    private func applyPush(_ pushed: ItemPushedEffectModel, keys: borrowing UnlockedKeys) throws {
        guard var record = try rows.config.fetchItemRecord(id: pushed.itemID, in: rows.tx) else { return }
        if let previousName = pushed.detachedPreviousName {
            try rows.insertDetachedTombstone(of: record, name: previousName, keys: keys)
        }
        let isUnchanged = record.valueFingerprint == pushed.sourceFingerprint
        let pushedValue = isUnchanged
            ? try Self.pushedBytes(of: record, normalize: pushed.didNormalizeValue, keys: keys)
            : nil
        defer { pushedValue?.wipe() }

        record.syncedName = pushed.syncedName
        record.syncedFingerprint = pushed.pushedFingerprint
        record.forcePush = false
        record.verifyState = .pending
        record.preWriteUpdatedAt = pushed.preWriteUpdatedAt
        if let pushedValue, let syncedAAD = ConfigFieldCipher.syncedAAD(of: record) {
            record.syncedValueCiphertext = try keys.seal(pushedValue, for: syncedAAD)
            if pushed.didNormalizeValue {
                // Local == GitHub (D32): the stored value becomes the normalized bytes gh received.
                record.valueCiphertext = try keys.seal(pushedValue, for: ConfigFieldCipher.valueAAD(of: record))
                record.valueFingerprint = pushed.pushedFingerprint
            }
        } else {
            record.syncedValueCiphertext = nil
        }
        try rows.config.updateItem(record, in: rows.tx)
    }

    /// The bytes gh received for `record`: its decrypted value, without trailing CR/LF when the
    /// push normalized it (D32). Nil when the value is missing. The caller wipes the result.
    private static func pushedBytes(
        of record: ConfigItemRecord,
        normalize: Bool,
        keys: borrowing UnlockedKeys
    ) throws -> SecretBytes? {
        let value: SecretBytes?
        do {
            value = try ConfigFieldCipher.openValue(of: record, keys: keys)
        } catch VaultError.locked {
            throw VaultError.locked
        } catch {
            throw SyncError.valueUnavailable(record.id)
        }
        guard let value, normalize else { return value }
        defer { value.wipe() }
        let keptCount = value.withUnsafeBytes { $0.count - ValueNormalizer.trailingNewlineCount(in: $0) }
        return value.prefix(keptCount)
    }

    /// A confirmed C6/C8 (`ItemDeletedEffectModel`).
    private func applyDelete(_ deleted: ItemDeletedEffectModel) throws {
        guard let row = try rows.config.fetchItemRecord(id: deleted.itemID, in: rows.tx) else { return }
        let environment = try row.environmentID.flatMap { try rows.config.fetchEnvironment(id: $0, in: rows.tx) }
        if row.isDeleted || environment?.isDeleted == true {
            try rows.config.deleteItem(id: row.id, in: rows.tx)
            return
        }
        // The delete half of an item rename: remove the tombstone holding the old name.
        let key = GitHubNameValidator.foldKey(deleted.syncedName)
        let siblings = try rows.config.fetchItemRecords(repositoryID: row.repositoryID, scope: row.scope, in: rows.tx)
        for candidate in siblings where candidate.isDeleted && candidate.kind == deleted.kind {
            if candidate.syncedName.map(GitHubNameValidator.foldKey) == key {
                try rows.config.deleteItem(id: candidate.id, in: rows.tx)
            }
        }
    }
}
