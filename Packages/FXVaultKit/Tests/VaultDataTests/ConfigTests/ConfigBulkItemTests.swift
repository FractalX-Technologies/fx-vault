import Foundation
import SyncEngine
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// Delete, Revert and Push on Next Sync on several items at once (v0.4.0 multi-selection): one
/// transaction each, all or nothing.
@Suite("ConfigRepository several items")
struct ConfigBulkItemTests {
    @Test func deleteItemsTombstonesSyncedAndRemovesUnsynced() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let synced = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        let kept = try harness.add(repo, "DB_URL", value: ConfigFixture.valueB)
        try harness.markSynced(repo)
        let unsynced = try harness.add(repo, "NEW_TOKEN", value: ConfigFixture.valueC)

        try harness.config.deleteItems([synced, unsynced], repositoryID: repo.id)

        #expect(try harness.status(synced) == .deleted)
        #expect(try harness.status(kept) == .synced)
        #expect(try harness.store.fetchItemRecord(id: unsynced) == nil)
        #expect(try harness.changeSet(repo).pendingCount == 1)
    }

    /// Sync's deletion review (§7.5) lists every item a multi-selection deleted.
    @Test func syncReviewCountsEveryDeletion() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let ids = try ["API_KEY", "DB_URL", "TOKEN"].map { try harness.add(repo, $0, value: ConfigFixture.valueA) }
        try harness.markSynced(repo)

        try harness.config.deleteItems(ids, repositoryID: repo.id)
        #expect(try harness.changeSet(repo).deletionCount == 3)
    }

    @Test func deleteItemsWritesNothingWhenOneFails() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        try harness.markSynced(repo)

        #expect(configError { try harness.config.deleteItems([id, ConfigItemID()], repositoryID: repo.id) } == .itemNotFound)
        #expect(try harness.status(id) == .synced)
        #expect(try harness.changeSet(repo).isEmpty)
    }

    @Test func deleteItemsNeedsAnEditableScope() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        try harness.markSynced(repo)
        var readOnly = repo
        readOnly.hasAdmin = false
        readOnly.hasPush = false
        try RepoStore(database: harness.database).update(readOnly)

        #expect(configError { try harness.config.deleteItems([id], repositoryID: repo.id) } == .readOnly(.adminRequired))
        #expect(try harness.status(id) == .synced)
    }

    @Test func revertItemsRestoresEachSyncedItem() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let edited = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        let deleted = try harness.add(repo, "DB_URL", value: ConfigFixture.valueB)
        try harness.markSynced(repo)
        try harness.config.editValue(edited, value: SecretBytes(utf8: ConfigFixture.valueC))
        try harness.config.deleteItem(deleted)
        #expect(try harness.changeSet(repo).pendingCount == 2)

        try harness.config.revertItems([edited, deleted], repositoryID: repo.id)

        #expect(try harness.status(edited) == .synced)
        #expect(try harness.reveal(edited) == ConfigFixture.valueA)
        #expect(try harness.status(deleted) == .synced)
        #expect(try harness.changeSet(repo).isEmpty)
    }

    @Test func requestPushForSeveralSecrets() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let first = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        let second = try harness.add(repo, "DB_URL", value: ConfigFixture.valueB)
        let variable = try harness.add(repo, "API_URL", kind: .variable, value: ConfigFixture.valueC)
        try harness.markSynced(repo)

        #expect(configError { try harness.config.requestPush([first, variable], repositoryID: repo.id) } == .edit(.pushNotApplicable))
        #expect(try harness.status(first) == .synced)

        try harness.config.requestPush([first, second], repositoryID: repo.id)
        #expect(try harness.status(first) == .willPush)
        #expect(try harness.status(second) == .willPush)
        #expect(try harness.changeSet(repo).pendingCount == 2)
    }
}
