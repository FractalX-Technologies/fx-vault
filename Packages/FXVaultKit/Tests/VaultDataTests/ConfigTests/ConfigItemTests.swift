import Foundation
import SyncEngine
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// The §7.1 coalescing matrix and item editing rules on the real store (M3).
@Suite("ConfigRepository items")
struct ConfigItemTests {
    // MARK: - Coalescing matrix

    @Test func addThenEditStaysOneAdd() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        try harness.config.editValue(id, value: SecretBytes(utf8: ConfigFixture.valueB))

        let states = try harness.states(repo)
        #expect(states.count == 1)
        #expect(try harness.status(id) == .added)
        #expect(try harness.reveal(id) == ConfigFixture.valueB)
        #expect(try harness.changeSet(repo).pendingCount == 1)
    }

    @Test func addThenDeleteRemovesTheRow() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        try harness.config.deleteItem(id)

        #expect(try harness.states(repo).isEmpty)
        #expect(try harness.changeSet(repo).isEmpty)
    }

    @Test func deleteThenReAddRevivesTheTombstone() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        try harness.markSynced(repo)

        try harness.config.deleteItem(id)
        #expect(try harness.state(id).isDeleted)
        #expect(try harness.status(id) == .deleted)

        let revived = try harness.add(repo, "api_key", value: ConfigFixture.valueB)
        #expect(revived == id)
        #expect(try harness.state(id).isDeleted == false)
        #expect(try harness.status(id) == .modified)
        #expect(try harness.reveal(id) == ConfigFixture.valueB)
        #expect(try harness.states(repo).count == 1)

        // Re-adding the synced value leaves nothing pending.
        try harness.config.deleteItem(id)
        _ = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        #expect(try harness.status(id) == .synced)
        #expect(try harness.changeSet(repo).isEmpty)
    }

    @Test func editThenRevertRestoresTheSyncedValue() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.add(repo, "DB_URL", kind: .variable, value: ConfigFixture.valueA)
        try harness.markSynced(repo)

        try harness.config.editValue(id, value: SecretBytes(utf8: ConfigFixture.valueB))
        #expect(try harness.status(id) == .modified)
        try harness.config.revertItem(id)

        #expect(try harness.status(id) == .synced)
        #expect(try harness.reveal(id) == ConfigFixture.valueA)
        #expect(try harness.changeSet(repo).isEmpty)
    }

    @Test func editBackToTheSyncedValueIsNoChange() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.add(repo, "DB_URL", value: ConfigFixture.valueA)
        try harness.markSynced(repo)

        try harness.config.editValue(id, value: SecretBytes(utf8: ConfigFixture.valueB))
        try harness.config.editValue(id, value: SecretBytes(utf8: ConfigFixture.valueA))
        #expect(try harness.status(id) == .synced)
        #expect(try harness.changeSet(repo).isEmpty)
    }

    @Test func swapIsTwoValueModifications() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let first = try harness.add(repo, "FIRST", value: ConfigFixture.valueA)
        let second = try harness.add(repo, "SECOND", value: ConfigFixture.valueB)
        try harness.markSynced(repo)

        // Swap through the UI rules: delete SECOND, rename FIRST into it (revival), re-add FIRST.
        try harness.config.deleteItem(second)
        let holder = try harness.config.renameItem(first, to: "SECOND")
        #expect(holder == second)
        let readded = try harness.add(repo, "FIRST", value: ConfigFixture.valueB)
        #expect(readded == first)

        #expect(try harness.reveal(first) == ConfigFixture.valueB)
        #expect(try harness.reveal(second) == ConfigFixture.valueA)
        #expect(try harness.status(first) == .modified)
        #expect(try harness.status(second) == .modified)
        let changeSet = try harness.changeSet(repo)
        #expect(changeSet.pendingCount == 2)
        #expect(changeSet.deletionCount == 0)
        #expect(try harness.states(repo).count == 2)
    }

    @Test func renameIntoATombstoneRevivesIt() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let source = try harness.add(repo, "OLD_TOKEN", value: ConfigFixture.valueA)
        let target = try harness.add(repo, "NEW_TOKEN", value: ConfigFixture.valueB)
        try harness.markSynced(repo)
        try harness.config.deleteItem(target)

        let holder = try harness.config.renameItem(source, to: "new_token")
        #expect(holder == target)
        // The value moved onto the tombstone and decrypts under its identity.
        #expect(try harness.reveal(target) == ConfigFixture.valueA)
        #expect(try harness.status(target) == .modified)
        #expect(try harness.state(source).isDeleted)
        #expect(try harness.state(source).name == "OLD_TOKEN")
        let changeSet = try harness.changeSet(repo)
        #expect(changeSet.pendingCount == 2)
        #expect(changeSet.deletionCount == 1)
    }

    @Test func renameReSealsTheValueUnderTheNewName() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.add(repo, "OLD_NAME", value: ConfigFixture.valueA)
        try harness.markSynced(repo)
        let before = try harness.record(id)

        let holder = try harness.config.renameItem(id, to: "new_name")
        #expect(holder == id)
        let after = try harness.record(id)
        #expect(after.name == "NEW_NAME")
        #expect(after.syncedName == "OLD_NAME")
        #expect(after.valueCiphertext != before.valueCiphertext)
        #expect(after.valueFingerprint == before.valueFingerprint)
        #expect(try harness.reveal(id) == ConfigFixture.valueA)
        #expect(try harness.status(id) == .added)

        // Renaming back is no change at all.
        try harness.config.renameItem(id, to: "OLD_NAME")
        #expect(try harness.changeSet(repo).isEmpty)
        #expect(try harness.reveal(id) == ConfigFixture.valueA)
    }

    // MARK: - Uniqueness and rules

    @Test func namesAreUniqueByFoldKeyPerScopeAndKind() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)

        let duplicate = configError { try harness.add(repo, "api_key", value: ConfigFixture.valueB) }
        #expect(duplicate == .edit(.nameTaken))

        // A variable of the same name, or the same name in an environment, is fine.
        try harness.add(repo, "API_KEY", kind: .variable, value: ConfigFixture.valueB)
        let environment = try harness.config.createEnvironment(in: repo.id, name: "staging")
        try harness.add(repo, "API_KEY", value: ConfigFixture.valueB, scope: .environment(environment))
        #expect(try harness.states(repo).count == 3)

        let invalid = configError { try harness.add(repo, "GITHUB_TOKEN", value: ConfigFixture.valueA) }
        #expect(invalid == .edit(.invalidName(.invalidName(.reservedPrefix))))
    }

    @Test func kindAndScopeAreImmutableOnceSynced() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.add(repo, "API_URL", value: ConfigFixture.valueA)
        try harness.markSynced(repo)

        // The store refuses a direct kind change.
        var record = try harness.record(id)
        record.kind = .variable
        #expect(throws: StoreError.immutableAfterSync) { try harness.store.updateItem(record) }

        // Convert creates a new row and tombstones the synced one.
        let converted = try harness.config.moveItem(id, toKind: .variable, scope: .repository)
        #expect(converted != id)
        #expect(try harness.state(id).isDeleted)
        #expect(try harness.state(converted).kind == .variable)
        #expect(try harness.reveal(converted) == ConfigFixture.valueA)
        #expect(try harness.status(converted) == .added)
        let changeSet = try harness.changeSet(repo)
        #expect(changeSet.pendingCount == 2)
        #expect(changeSet.deletionCount == 1)
    }

    @Test func moveToAnEnvironmentAndUnsyncedConvert() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let environment = try harness.config.createEnvironment(in: repo.id, name: "production")
        let id = try harness.add(repo, "REGION", kind: .variable, value: ConfigFixture.valueC)

        let moved = try harness.config.moveItem(id, toKind: .variable, scope: .environment(environment))
        #expect(try harness.store.fetchItemRecord(id: id) == nil)
        #expect(try harness.state(moved).scope == .environment(environment))
        #expect(try harness.reveal(moved) == ConfigFixture.valueC)
    }

    @Test func valueMissingSecretCannotBecomeAVariableOrBeRevealed() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try insertValueMissingSecret(harness, repo: repo, name: "IMPORTED_TOKEN")

        #expect(configError { _ = try harness.config.moveItem(id, toKind: .variable, scope: .repository) } == .valueMissing)
        #expect(configError { _ = try harness.config.reveal(id) } == .valueMissing)
        // Moving it as a secret keeps it value-missing, so the change is blocked.
        let environment = try harness.config.createEnvironment(in: repo.id, name: "staging")
        let moved = try harness.config.moveItem(id, toKind: .secret, scope: .environment(environment))
        #expect(try harness.status(moved) == .blocked)
    }

    @Test func valuesAreNormalizedOnEntry() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let result = try harness.config.addItem(
            repositoryID: repo.id,
            scope: .repository,
            kind: .secret,
            name: "SSH_KEY",
            value: SecretBytes(utf8: "-----BEGIN KEY-----\nAAAA\n-----END KEY-----\r\n")
        )
        #expect(result.didStripTrailingNewlines)
        #expect(try harness.reveal(result.itemID) == "-----BEGIN KEY-----\nAAAA\n-----END KEY-----")

        let empty = configError { try harness.add(repo, "EMPTY", value: "\n") }
        #expect(empty == .validation(.emptyValue))
        let large = String(repeating: "x", count: Limits.maxValueBytes + 1)
        #expect(configError { try harness.add(repo, "LARGE", value: large) } == .validation(.valueTooLarge(limit: Limits.maxValueBytes)))
    }

    // MARK: - Fill, revert, discard

    @Test func fillDefaultsToAlreadyOnGitHub() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try insertValueMissingSecret(harness, repo: repo, name: "DEPLOY_TOKEN")

        try harness.config.fillValue(id, value: SecretBytes(utf8: ConfigFixture.valueA), pushOnNextSync: false)
        let state = try harness.state(id)
        #expect(state.hasValue)
        #expect(state.hasSyncedValue)
        #expect(state.valueFingerprint == state.syncedFingerprint)
        #expect(try harness.status(id) == .synced)
        #expect(try harness.reveal(id) == ConfigFixture.valueA)
        #expect(try harness.changeSet(repo).isEmpty)

        // Fill is only for a missing value.
        let again = configError { _ = try harness.config.fillValue(id, value: SecretBytes(utf8: "x"), pushOnNextSync: false) }
        #expect(again == .edit(.valueNotMissing))
    }

    @Test func fillCanPushOnNextSync() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try insertValueMissingSecret(harness, repo: repo, name: "DEPLOY_TOKEN")
        #expect(try harness.changeSet(repo).isEmpty)

        try harness.config.fillValue(id, value: SecretBytes(utf8: ConfigFixture.valueA), pushOnNextSync: true)
        #expect(try harness.state(id).forcePush)
        #expect(try harness.status(id) == .modified)
        #expect(try harness.changeSet(repo).pendingCount == 1)
    }

    @Test func discardAllRevertsEverything() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let kept = try harness.add(repo, "KEPT", value: ConfigFixture.valueA)
        let renamed = try harness.add(repo, "RENAMED", value: ConfigFixture.valueB)
        let environment = try harness.config.createEnvironment(in: repo.id, name: "staging")
        try harness.markSynced(repo)

        try harness.config.editValue(kept, value: SecretBytes(utf8: ConfigFixture.valueC))
        try harness.config.renameItem(renamed, to: "RENAMED_AGAIN")
        try harness.add(repo, "NEW_ONE", value: ConfigFixture.valueC)
        try harness.config.deleteEnvironment(environment)
        let fresh = try harness.config.createEnvironment(in: repo.id, name: "qa")
        try harness.add(repo, "IN_QA", value: ConfigFixture.valueC, scope: .environment(fresh))
        #expect(try harness.changeSet(repo).pendingCount > 0)

        try harness.config.discardAll(repositoryID: repo.id)
        #expect(try harness.changeSet(repo).isEmpty)
        #expect(try harness.reveal(kept) == ConfigFixture.valueA)
        #expect(try harness.state(renamed).name == "RENAMED")
        #expect(try harness.reveal(renamed) == ConfigFixture.valueB)
        #expect(try harness.states(repo).count == 2)
        #expect(try harness.store.fetchEnvironment(id: fresh) == nil)
        #expect(try harness.store.fetchEnvironment(id: environment)?.isDeleted == false)
    }

    // MARK: - Capability, scope and locking

    @Test func readOnlyRepositoriesRefuseEdits() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository(hasAdmin: false, hasPush: true)
        #expect(configError { try harness.add(repo, "API_KEY", value: ConfigFixture.valueA) } == .readOnly(.adminRequired))
        #expect(configError { _ = try harness.config.createEnvironment(in: repo.id, name: "staging") } == .readOnly(.adminRequired))

        // With the repo-level WRITE policy, repository items are editable but environments are not.
        let writer = ConfigRepository(session: harness.session, clock: harness.clock, writePolicy: .repoLevelOnly)
        _ = try writer.addItem(repositoryID: repo.id, scope: .repository, kind: .secret, name: "API_KEY", value: SecretBytes(utf8: "v"))
        #expect(configError { _ = try writer.createEnvironment(in: repo.id, name: "staging") } == .readOnly(.adminRequired))

        let archived = try harness.seedRepository(name: "repo-archived", isArchived: true)
        #expect(configError { try harness.add(archived, "API_KEY", value: ConfigFixture.valueA) } == .readOnly(.archived))
    }

    @Test func itemsOfADeletedEnvironmentAreFrozen() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let environment = try harness.config.createEnvironment(in: repo.id, name: "staging")
        let id = try harness.add(repo, "TOKEN", value: ConfigFixture.valueA, scope: .environment(environment))
        try harness.markSynced(repo)
        try harness.config.deleteEnvironment(environment)

        #expect(configError { try harness.config.editValue(id, value: SecretBytes(utf8: "x")) } == .environmentDeleted)
        #expect(configError { try harness.add(repo, "OTHER", value: "x", scope: .environment(environment)) } == .environmentDeleted)
        #expect(configError { try harness.add(repo, "OTHER", value: "x", scope: .environment(EnvironmentID())) } == .environmentNotFound)
    }

    @Test func editsNeedAnUnlockedVault() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.add(repo, "TOKEN", value: ConfigFixture.valueA)
        harness.manager.lock()

        #expect(configError { try harness.add(repo, "OTHER", value: ConfigFixture.valueB) } == .vault(.locked))
        #expect(configError { _ = try harness.config.reveal(id) } == .vault(.locked))
        #expect(configError { try harness.config.deleteItem(id) } == .vault(.locked))
        #expect(try harness.states(repo).count == 1)
    }

    @Test func scopeCapacityIsEnforced() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let environment = try harness.config.createEnvironment(in: repo.id, name: "staging")
        let scope = ConfigScope.environment(environment)
        try harness.config.batch(repositoryID: repo.id) { batch in
            for index in 0..<Limits.maxSecretsPerEnvironment {
                try batch.add(scope: scope, kind: .secret, name: "S_\(index)", value: SecretBytes(utf8: "v"))
            }
        }
        let full = configError { try harness.add(repo, "ONE_MORE", value: "v", scope: scope) }
        #expect(full == .validation(.scopeFull(kind: .secret, limit: Limits.maxSecretsPerEnvironment)))
    }

    // MARK: - Helpers

    /// A synced secret whose value is missing locally, as an import stores it.
    private func insertValueMissingSecret(_ harness: ConfigHarness, repo: RepoModel, name: String) throws -> ConfigItemID {
        let record = ConfigItemRecord(
            repositoryID: repo.id,
            scope: .repository,
            kind: .secret,
            name: name,
            valueCiphertext: nil,
            valueFingerprint: nil,
            syncedName: name,
            remoteUpdatedAt: ManualClock.defaultStart,
            provenance: .github,
            createdAt: ManualClock.defaultStart,
            updatedAt: ManualClock.defaultStart
        )
        try harness.store.insertItem(record)
        return record.id
    }
}
