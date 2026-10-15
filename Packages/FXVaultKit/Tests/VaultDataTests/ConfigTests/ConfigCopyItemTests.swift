import Foundation
import SyncEngine
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Copy between scopes of one repository (v0.4.0 copy and paste): values re-encrypted for the new
/// rows, name conflicts kept or replaced, secrets without a value left out, one transaction.
@Suite("ConfigRepository copy between scopes")
struct ConfigCopyItemTests {
    @Test func copiesFromTheRepositoryLevelIntoAnEnvironment() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let secret = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        let variable = try harness.add(repo, "API_URL", kind: .variable, value: ConfigFixture.valueB)
        let staging = try harness.config.createEnvironment(in: repo.id, name: "staging")

        let result = try harness.config.copyItems([secret, variable], to: .environment(staging), repositoryID: repo.id, conflicts: .keep)

        #expect(result == ItemCopyResultModel(added: 2))
        let copies = try harness.store.fetchItemRecords(repositoryID: repo.id, scope: .environment(staging))
        #expect(Set(copies.map(\.name)) == ["API_KEY", "API_URL"])
        let copiedSecret = try #require(copies.first { $0.name == "API_KEY" })
        #expect(copiedSecret.kind == .secret)
        #expect(try harness.reveal(copiedSecret.id) == ConfigFixture.valueA)
        #expect(try harness.status(copiedSecret.id) == .added)
        #expect(try harness.reveal(secret) == ConfigFixture.valueA, "the source stays")
        #expect(try harness.states(repo).count == 4)
    }

    @Test func conflictsAreListedThenKeptOrReplaced() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let staging = try harness.config.createEnvironment(in: repo.id, name: "staging")
        let source = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        let fresh = try harness.add(repo, "NEW_TOKEN", value: ConfigFixture.valueC)
        let target = try harness.add(repo, "api_key", value: ConfigFixture.valueB, scope: .environment(staging))

        #expect(try harness.config.copyConflicts([source, fresh], to: .environment(staging), repositoryID: repo.id) == ["API_KEY"])

        let kept = try harness.config.copyItems([source], to: .environment(staging), repositoryID: repo.id, conflicts: .keep)
        #expect(kept == ItemCopyResultModel(kept: 1))
        #expect(try harness.reveal(target) == ConfigFixture.valueB)

        let replaced = try harness.config.copyItems([source], to: .environment(staging), repositoryID: repo.id, conflicts: .replace)
        #expect(replaced == ItemCopyResultModel(replaced: 1))
        #expect(try harness.reveal(target) == ConfigFixture.valueA)
    }

    @Test func secretsWithoutAValueAreLeftOut() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let staging = try harness.config.createEnvironment(in: repo.id, name: "staging")
        let missing = ConfigItemRecord(
            repositoryID: repo.id,
            scope: .repository,
            kind: .secret,
            name: "DEPLOY_TOKEN",
            valueCiphertext: nil,
            valueFingerprint: nil,
            syncedName: "DEPLOY_TOKEN",
            remoteUpdatedAt: ManualClock.defaultStart,
            provenance: .github,
            createdAt: ManualClock.defaultStart,
            updatedAt: ManualClock.defaultStart
        )
        try harness.store.insertItem(missing)
        let withValue = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)

        let result = try harness.config.copyItems([missing.id, withValue], to: .environment(staging), repositoryID: repo.id, conflicts: .keep)

        #expect(result == ItemCopyResultModel(added: 1, withoutValue: ["DEPLOY_TOKEN"]))
        #expect(try harness.store.fetchItemRecords(repositoryID: repo.id, scope: .environment(staging)).map(\.name) == ["API_KEY"])
    }

    @Test func aCopyIntoTheSameScopeChangesNothing() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)

        #expect(try harness.config.copyConflicts([id], to: .repository, repositoryID: repo.id).isEmpty)
        #expect(try harness.config.copyItems([id], to: .repository, repositoryID: repo.id, conflicts: .replace) == ItemCopyResultModel())
        #expect(try harness.states(repo).count == 1)
    }

    @Test func aCopyRevivesAnItemDeletedInTheTarget() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let staging = try harness.config.createEnvironment(in: repo.id, name: "staging")
        let target = try harness.add(repo, "API_KEY", value: ConfigFixture.valueB, scope: .environment(staging))
        try harness.markSynced(repo)
        try harness.config.deleteItem(target)
        let source = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)

        let result = try harness.config.copyItems([source], to: .environment(staging), repositoryID: repo.id, conflicts: .keep)

        #expect(result == ItemCopyResultModel(added: 1))
        #expect(try harness.state(target).isDeleted == false, "the deleted row comes back")
        #expect(try harness.status(target) == .modified)
        #expect(try harness.reveal(target) == ConfigFixture.valueA)
    }

    @Test func aCopyNeedsAnEditableTargetAndWritesNothingOtherwise() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let staging = try harness.config.createEnvironment(in: repo.id, name: "staging")
        let source = try harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        var readOnly = repo
        readOnly.hasAdmin = false
        readOnly.hasPush = false
        try RepoStore(database: harness.database).update(readOnly)

        #expect(configError {
            try harness.config.copyItems([source], to: .environment(staging), repositoryID: repo.id, conflicts: .keep)
        } == .readOnly(.adminRequired))
        #expect(try harness.store.fetchItemRecords(repositoryID: repo.id, scope: .environment(staging)).isEmpty)
    }
}
