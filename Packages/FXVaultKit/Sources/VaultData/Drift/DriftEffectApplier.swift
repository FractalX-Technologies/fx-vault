import Foundation
import GitHubKit
import SyncEngine
import VaultCore
import VaultCrypto
import VaultStore

/// Applies one drift resolution's `DriftEffectModel`s to the vault rows inside one
/// `VaultSession.write` transaction (§7.7), with the semantics documented on each effect.
///
/// Every effect first checks that GitHub still has what the finding saw, against the fresh
/// read in ``DriftRemoteStateModel``: a variable's listed value must still fingerprint to the
/// finding's value, a secret's `updatedAt` must be the same instant, a deleted item or
/// environment must still be absent. Otherwise it throws ``DriftRepositoryError/stale`` and the
/// whole transaction rolls back. Values come from that read and are sealed for the row they
/// land in (the AAD binds the row and its name).
struct DriftEffectApplier {
    let rows: SyncRowWriter
    let keys: UnlockedKeys
    let repositoryID: RepoID
    let remote: DriftRemoteStateModel

    private var now: Date {
        rows.now
    }

    func apply(_ effect: DriftEffectModel) throws {
        switch effect {
        case .rebaseVariable(let itemID, let fingerprint):
            try rebaseVariable(itemID, fingerprint: fingerprint)
        case .adoptRemoteVariable(let itemID, let fingerprint):
            try adoptRemoteVariable(itemID, fingerprint: fingerprint)
        case .rebaseSecret(let itemID, let remoteUpdatedAt, let forcePush):
            try requireListedSecret(updatedAt: remoteUpdatedAt)
            try updateItem(itemID) { record in
                record.remoteUpdatedAt = remoteUpdatedAt
                if forcePush { record.forcePush = true }
            }
        case .clearSecretValue(let itemID, let remoteUpdatedAt):
            try requireListedSecret(updatedAt: remoteUpdatedAt)
            try updateItem(itemID) { record in
                Self.takeSyncedIdentity(&record)
                record.clearValues()
                record.remoteUpdatedAt = remoteUpdatedAt
            }
        case .createTombstone(let placement):
            try insertListed(placement, isTombstone: true)
        case .importItem(let placement):
            try insertListed(placement, isTombstone: false)
        case .detachSyncedIdentity(let itemID):
            try detachSyncedIdentity(itemID)
        case .adoptRemoteIdentity(let itemID, let remoteName, let remoteUpdatedAt, let fingerprint):
            try adoptRemoteIdentity(itemID, remoteName: remoteName, remoteUpdatedAt: remoteUpdatedAt, fingerprint: fingerprint, replace: false)
        case .replaceWithRemote(let itemID, let remoteName, let remoteUpdatedAt, let fingerprint):
            try adoptRemoteIdentity(itemID, remoteName: remoteName, remoteUpdatedAt: remoteUpdatedAt, fingerprint: fingerprint, replace: true)
        case .markItemUnsynced(let itemID):
            try requireItemAbsent()
            try updateItem(itemID) { $0.markUnsynced() }
        case .deleteLocalItem(let itemID):
            try requireItemAbsent()
            guard try rows.config.deleteItem(id: itemID, in: rows.tx) else { throw DriftRepositoryError.stale }
        case .createEnvironmentTombstone(let name, let githubID):
            try insertEnvironmentTombstone(name: name, githubID: githubID)
        case .importEnvironment(_, let githubID, _):
            try importEnvironment(githubID: githubID)
        case .adoptRemoteEnvironment(let environmentID, let remoteName, let githubID, let remotePolicy, let adoptPolicy):
            let listing = try requireEnvironment(githubID: githubID, policy: remotePolicy)
            try updateEnvironment(environmentID) { environment in
                environment.syncedName = remoteName
                environment.githubEnvID = githubID
                environment.syncedBranchPolicy = remotePolicy
                environment.foreignRulesJSON = listing.foreignRulesJSON
                environment.remoteUpdatedAt = listing.updatedAt
                if adoptPolicy {
                    environment.branchPolicy = Self.policy(remotePolicy, patterns: environment.branchPolicy.patterns)
                }
            }
        case .markEnvironmentUnsynced(let environmentID):
            try markEnvironmentUnsynced(environmentID)
        case .deleteLocalEnvironment(let environmentID):
            try requireEnvironmentAbsent()
            guard try rows.config.deleteEnvironment(id: environmentID, in: rows.tx) else { throw DriftRepositoryError.stale }
        case .rebaseEnvironmentPolicy(let environmentID, let remotePolicy):
            _ = try requireEnvironment(githubID: nil, policy: remotePolicy)
            try updateEnvironment(environmentID) { $0.syncedBranchPolicy = remotePolicy }
        case .adoptRemoteEnvironmentPolicy(let environmentID, let remotePolicy):
            try adoptRemotePolicy(environmentID, remotePolicy: remotePolicy)
        }
    }

    // MARK: - Variables and secrets

    private func rebaseVariable(_ itemID: ConfigItemID, fingerprint: Data) throws {
        let value = try listedVariable(matching: fingerprint, rowID: itemID)
        try updateItem(itemID) { record in
            guard let aad = ConfigFieldCipher.syncedAAD(of: record) else { throw DriftRepositoryError.stale }
            record.syncedValueCiphertext = try keys.seal(value, for: aad)
            record.syncedFingerprint = fingerprint
        }
    }

    private func adoptRemoteVariable(_ itemID: ConfigItemID, fingerprint: Data) throws {
        let value = try listedVariable(matching: fingerprint, rowID: itemID)
        try updateItem(itemID) { record in
            Self.takeSyncedIdentity(&record)
            try ConfigFieldCipher.setValue(value, on: &record, keys: keys)
            try ConfigFieldCipher.setSyncedValue(value, on: &record, keys: keys)
        }
    }

    /// Conflict resolutions of a never-synced row (or a renamed row's new name) whose name
    /// GitHub already has: the row takes the remote identity, keeping its value
    /// (`replace == false`, pushed as a modify) or taking GitHub's (`replace == true`).
    private func adoptRemoteIdentity(
        _ itemID: ConfigItemID,
        remoteName: String,
        remoteUpdatedAt: Date?,
        fingerprint: Data?,
        replace: Bool
    ) throws {
        guard let record = try rows.config.fetchItemRecord(id: itemID, in: rows.tx) else {
            throw DriftRepositoryError.stale
        }
        let syncedName = try GitHubNameValidator.validate(remoteName)
        var updated = record
        updated.syncedName = syncedName
        updated.remoteUpdatedAt = remoteUpdatedAt
        updated.forcePush = false
        updated.forcePushRequestedAt = nil
        updated.verifyState = .verified
        switch record.kind {
        case .variable:
            guard let fingerprint else { throw DriftRepositoryError.stale }
            let value = try listedVariable(matching: fingerprint, rowID: itemID)
            if replace {
                try ConfigFieldCipher.setValue(value, on: &updated, keys: keys)
            }
            try ConfigFieldCipher.setSyncedValue(value, on: &updated, keys: keys)
        case .secret:
            try requireListedSecret(updatedAt: remoteUpdatedAt)
            updated.syncedValueCiphertext = nil
            updated.syncedFingerprint = nil
            if replace {
                updated.valueCiphertext = nil
                updated.valueFingerprint = nil
            } else {
                updated.forcePush = true
            }
        }
        updated.updatedAt = now
        try rows.config.updateItem(updated, in: rows.tx)
    }

    /// Before a renamed synced row takes another remote name: a tombstone keeps its current
    /// remote identity, so the old name is still deleted on GitHub.
    private func detachSyncedIdentity(_ itemID: ConfigItemID) throws {
        guard let record = try rows.config.fetchItemRecord(id: itemID, in: rows.tx) else {
            throw DriftRepositoryError.stale
        }
        guard let syncedName = record.syncedName else { return }
        try rows.insertDetachedTombstone(of: record, name: syncedName, keys: keys)
        try updateItem(itemID) { $0.markUnsynced() }
    }

    /// A new row for a remote-only item: a tombstone ("Keep local": the next Sync deletes it) or
    /// an imported row ("Accept GitHub").
    private func insertListed(_ placement: DriftItemPlacementModel, isTombstone: Bool) throws {
        guard let listed = remote.item else { throw DriftRepositoryError.stale }
        if placement.kind == .secret {
            try requireListedSecret(updatedAt: placement.remoteUpdatedAt)
        }
        let name = try GitHubNameValidator.validate(placement.name)
        try rows.insertListedItem(
            repositoryID: repositoryID,
            scope: placement.scope,
            kind: placement.kind,
            name: name,
            remoteUpdatedAt: placement.remoteUpdatedAt,
            listedValue: listed.value,
            isTombstone: isTombstone,
            keys: keys
        )
    }

    // MARK: - Environments

    private func insertEnvironmentTombstone(name: String, githubID: Int64) throws {
        let listing = try requireEnvironment(githubID: githubID, policy: nil)
        let validName = try EnvironmentNameValidator.validate(name)
        let siblings = try rows.config.fetchEnvironments(repositoryID: repositoryID, in: rows.tx)
        guard !siblings.contains(where: { $0.nameKey == EnvironmentNameValidator.foldKey(validName) }) else {
            throw DriftRepositoryError.stale
        }
        let policy = listing.branchPolicyKind
        try rows.config.insertEnvironment(
            EnvironmentModel(
                repositoryID: repositoryID,
                name: validName,
                syncedName: validName,
                isDeleted: true,
                branchPolicy: Self.policy(policy, patterns: []),
                syncedBranchPolicy: policy,
                foreignRulesJSON: listing.foreignRulesJSON,
                githubEnvID: githubID,
                remoteUpdatedAt: listing.updatedAt,
                sortOrder: Self.nextSortOrder(siblings),
                createdAt: now,
                updatedAt: now
            ),
            in: rows.tx
        )
    }

    /// "Accept GitHub" for a remote environment: stored like an import (policy, patterns with
    /// their GitHub ids, foreign rules; variables with values, secrets value-missing).
    private func importEnvironment(githubID: Int64) throws {
        _ = try requireEnvironment(githubID: githubID, policy: nil)
        guard let environment = remote.environment else { throw DriftRepositoryError.stale }
        let siblings = try rows.config.fetchEnvironments(repositoryID: repositoryID, in: rows.tx)
        guard !siblings.contains(where: { $0.nameKey == EnvironmentNameValidator.foldKey(environment.name) }) else {
            throw DriftRepositoryError.stale
        }
        let model = RepoImportWriter.environmentModel(
            environment,
            id: EnvironmentID(),
            repositoryID: repositoryID,
            sortOrder: Self.nextSortOrder(siblings),
            now: now
        )
        try rows.config.insertEnvironment(model, in: rows.tx)
        let scope = ConfigScope.environment(model.id)
        for secret in environment.secrets {
            try rows.insertListedItem(
                repositoryID: repositoryID,
                scope: scope,
                kind: .secret,
                name: secret.name,
                remoteUpdatedAt: secret.updatedAt,
                listedValue: nil,
                isTombstone: false,
                keys: keys
            )
        }
        for variable in environment.variables {
            try rows.insertListedItem(
                repositoryID: repositoryID,
                scope: scope,
                kind: .variable,
                name: variable.name,
                remoteUpdatedAt: variable.updatedAt,
                listedValue: variable.value,
                isTombstone: false,
                keys: keys
            )
        }
    }

    /// "Keep local" for an environment deleted on GitHub: it becomes a pending create again
    /// with every live item a pending add.
    private func markEnvironmentUnsynced(_ environmentID: EnvironmentID) throws {
        try requireEnvironmentAbsent()
        try updateEnvironment(environmentID) { environment in
            environment.syncedName = nil
            environment.syncedBranchPolicy = nil
            environment.githubEnvID = nil
            environment.remoteUpdatedAt = nil
            environment.foreignRulesJSON = nil
        }
        try rows.unsyncPatterns(of: environmentID)
        let items = try rows.config.fetchItemRecords(repositoryID: repositoryID, scope: .environment(environmentID), in: rows.tx)
        for item in items {
            if item.isDeleted {
                try rows.config.deleteItem(id: item.id, in: rows.tx)
            } else {
                try updateItem(item.id) { $0.markUnsynced() }
            }
        }
    }

    /// "Accept GitHub" for a policy change: the policy (and for custom, GitHub's patterns with
    /// their ids) replaces the local one.
    private func adoptRemotePolicy(_ environmentID: EnvironmentID, remotePolicy: BranchPolicyKind) throws {
        _ = try requireEnvironment(githubID: nil, policy: remotePolicy)
        let existing = try rows.config.fetchPatterns(environmentID: environmentID, in: rows.tx)
        var patterns: [BranchPatternModel] = []
        if remotePolicy == .custom {
            guard let listed = remote.environment?.patterns else { throw DriftRepositoryError.stale }
            for pattern in existing {
                try rows.config.deletePattern(id: pattern.id, in: rows.tx)
            }
            for policy in listed {
                let pattern = BranchPatternModel(
                    environmentID: environmentID,
                    pattern: policy.name,
                    type: policy.type,
                    githubPolicyID: policy.id
                )
                try rows.config.insertPattern(pattern, in: rows.tx)
                patterns.append(pattern)
            }
        } else {
            try rows.unsyncPatterns(of: environmentID)
        }
        try updateEnvironment(environmentID) { environment in
            environment.branchPolicy = Self.policy(remotePolicy, patterns: patterns)
            environment.syncedBranchPolicy = remotePolicy
        }
    }

    // MARK: - Freshness checks

    /// The listed variable value, when it still fingerprints to `fingerprint` for `rowID`.
    private func listedVariable(matching fingerprint: Data, rowID: ConfigItemID) throws -> SecretBytes {
        guard let value = remote.item?.value, keys.fingerprintMatches(fingerprint, value: value, rowID: rowID) else {
            throw DriftRepositoryError.stale
        }
        return value
    }

    private func requireListedSecret(updatedAt: Date?) throws {
        guard let listed = remote.item, DriftDetector.isSameTimestamp(listed.updatedAt, updatedAt) else {
            throw DriftRepositoryError.stale
        }
    }

    private func requireItemAbsent() throws {
        guard remote.item == nil else { throw DriftRepositoryError.stale }
    }

    /// The listed environment, checked against the finding's id and policy when given.
    private func requireEnvironment(githubID: Int64?, policy: BranchPolicyKind?) throws -> GHEnvironmentDTO {
        guard let listing = remote.environment?.listing,
              githubID.map({ $0 == listing.id }) ?? true,
              policy.map({ $0 == listing.branchPolicyKind }) ?? true
        else { throw DriftRepositoryError.stale }
        return listing
    }

    private func requireEnvironmentAbsent() throws {
        guard remote.environment == nil else { throw DriftRepositoryError.stale }
    }

    // MARK: - Row helpers

    private func updateItem(_ id: ConfigItemID, _ body: (inout ConfigItemRecord) throws -> Void) throws {
        let now = now
        let found = try rows.updateItem(id) { record in
            try body(&record)
            record.updatedAt = now
        }
        guard found else { throw DriftRepositoryError.stale }
    }

    private func updateEnvironment(_ id: EnvironmentID, _ body: (inout EnvironmentModel) throws -> Void) throws {
        let now = now
        let found = try rows.updateEnvironment(id) { environment in
            try body(&environment)
            environment.updatedAt = now
        }
        guard found else { throw DriftRepositoryError.stale }
    }

    /// `name := synced_name`, `is_deleted := 0`, `force_push := 0` (the row takes GitHub's state).
    private static func takeSyncedIdentity(_ record: inout ConfigItemRecord) {
        if let syncedName = record.syncedName {
            record.name = syncedName
        }
        record.isDeleted = false
        record.forcePush = false
        record.forcePushRequestedAt = nil
        record.verifyState = .verified
    }


    static func policy(_ kind: BranchPolicyKind, patterns: [BranchPatternModel]) -> DeploymentBranchPolicyModel {
        switch kind {
        case .all: .all
        case .protected: .protectedBranches
        case .custom: .custom(patterns)
        }
    }

    private static func nextSortOrder(_ environments: [EnvironmentModel]) -> Int {
        (environments.map(\.sortOrder).max() ?? -1) + 1
    }
}
