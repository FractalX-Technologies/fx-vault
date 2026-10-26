import Foundation
import SyncEngine
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// The notes' Review saves a scope's edits in one transaction (1.0 N2): deletions, renames and
/// new values, then additions, all or nothing.
@Suite("ConfigRepository place edits")
struct ConfigPlaceEditsTests {
    @Test func everyEditOfAScopeIsSavedAsPendingChanges() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let renamed = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        let variable = try harness.add(repo, "LOG_LEVEL", kind: .variable, value: "info")
        let removed = try harness.add(repo, "OLD_TOKEN", value: ConfigFixture.valueB)
        try harness.markSynced(repo)

        let edits = PlaceItemEditsModel(
            deletions: [removed],
            changes: [
                .init(id: renamed, name: "API_TOKEN", value: SecretBytes(utf8: "\(ConfigFixture.valueC)\r\n")),
                .init(id: variable, value: SecretBytes(utf8: "debug")),
            ],
            additions: [.init(kind: .secret, name: "NEW_KEY", value: SecretBytes(utf8: ConfigFixture.valueB))]
        )
        defer { edits.wipe() }
        try harness.config.applyEdits(edits, repositoryID: repo.id, scope: .repository)

        let items = try harness.store.fetchItems(repositoryID: repo.id, scope: .repository)
        let token = try #require(items.first { $0.name == "API_TOKEN" && !$0.isDeleted })
        #expect(try harness.reveal(token.id) == ConfigFixture.valueC)
        #expect(try harness.reveal(variable) == "debug")
        #expect(try harness.status(removed) == .deleted)
        let added = try #require(items.first { $0.name == "NEW_KEY" })
        #expect(try harness.reveal(added.id) == ConfigFixture.valueB)
        // GitHub has no rename: API_TOKEN is set and API_KEY deleted by the next Sync.
        #expect(try harness.changeSet(repo).pendingCount == 5)
    }

    /// A secret listed from GitHub without a value is filled and pushed on the next Sync, as Fill
    /// does by default.
    @Test func aValueForAValueMissingSecretFillsIt() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try insertValueMissingSecret(harness, repo: repo, name: "DEPLOY_TOKEN")

        let edits = PlaceItemEditsModel(changes: [.init(id: id, value: SecretBytes(utf8: ConfigFixture.valueA))])
        defer { edits.wipe() }
        try harness.config.applyEdits(edits, repositoryID: repo.id, scope: .repository)

        #expect(try harness.reveal(id) == ConfigFixture.valueA)
        #expect(try harness.state(id).forcePush)
        #expect(try harness.status(id) == .modified)
    }

    @Test func nothingIsWrittenWhenOneEditFails() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let removed = try harness.add(repo, "OLD_TOKEN", value: ConfigFixture.valueA)
        try harness.add(repo, "TAKEN", value: ConfigFixture.valueB)
        try harness.markSynced(repo)

        let edits = PlaceItemEditsModel(
            deletions: [removed],
            additions: [.init(kind: .secret, name: "TAKEN", value: SecretBytes(utf8: ConfigFixture.valueC))]
        )
        defer { edits.wipe() }
        let error = configError { try harness.config.applyEdits(edits, repositoryID: repo.id, scope: .repository) }

        #expect(error == .edit(.nameTaken))
        #expect(try harness.status(removed) == .synced)
        #expect(try harness.changeSet(repo).isEmpty)
    }

    @Test func anItemOfAnotherScopeIsRefused() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let environment = try harness.config.createEnvironment(in: repo.id, name: "production")
        let elsewhere = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA, scope: .environment(environment))

        let edits = PlaceItemEditsModel(deletions: [elsewhere])
        let error = configError { try harness.config.applyEdits(edits, repositoryID: repo.id, scope: .repository) }

        #expect(error == .itemNotFound)
        #expect(try harness.status(elsewhere) == .added)
    }

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
