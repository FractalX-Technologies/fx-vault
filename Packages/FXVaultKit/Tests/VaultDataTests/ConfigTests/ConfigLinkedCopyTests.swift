import Foundation
import SyncEngine
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Copy across repositories and linked copies (v0.4.1, tasks/todo.md L1–L5): any repository of
/// the vault is a target, every copy is linked to its source, the popover's places and
/// comparisons, Unlink, and "Also update linked copies".
@Suite("ConfigRepository linked copies")
struct ConfigLinkedCopyTests {
    // MARK: - Copy across repositories (L1)

    @Test func copiesIntoAnotherRepositoryAndLinksBothRows() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let repoB = try harness.seedRepository(name: "repo-b")
        let source = try harness.add(repoA, "API_KEY", value: ConfigFixture.valueA)

        #expect(try harness.config.copyConflicts([source], to: .repository, repositoryID: repoB.id).isEmpty)
        let result = try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)

        #expect(result == ItemCopyResultModel(added: 1))
        let copy = try #require(try harness.store.fetchItemRecords(repositoryID: repoB.id).first)
        #expect(copy.name == "API_KEY" && copy.kind == .secret)
        #expect(try harness.reveal(copy.id) == ConfigFixture.valueA)
        #expect(try harness.status(copy.id) == .added)
        let link = try #require(try harness.record(source).linkID)
        #expect(copy.linkID == link)
    }

    @Test func copiesIntoARepositoryOfAnotherAccount() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let other = try Self.seedRepository(harness, login: "user-b", name: "repo-b")
        let staging = try harness.config.createEnvironment(in: other.id, name: "staging")
        let source = try harness.add(repoA, "API_URL", kind: .variable, value: ConfigFixture.valueB)

        let result = try harness.config.copyItems([source], to: .environment(staging), repositoryID: other.id, conflicts: .keep)

        #expect(result == ItemCopyResultModel(added: 1))
        let copy = try #require(try harness.store.fetchItemRecords(repositoryID: other.id, scope: .environment(staging)).first)
        #expect(copy.kind == .variable)
        #expect(try harness.reveal(copy.id) == ConfigFixture.valueB)
    }

    @Test func conflictsInAnotherRepositoryAreListedAndOnlyAReplacementIsLinked() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let repoB = try harness.seedRepository(name: "repo-b")
        let source = try harness.add(repoA, "API_KEY", value: ConfigFixture.valueA)
        let target = try harness.add(repoB, "api_key", value: ConfigFixture.valueB)

        #expect(try harness.config.copyConflicts([source], to: .repository, repositoryID: repoB.id) == ["API_KEY"])

        #expect(try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)
            == ItemCopyResultModel(kept: 1))
        #expect(try harness.record(target).linkID == nil, "a kept item is not a copy")
        #expect(try harness.record(source).linkID == nil)

        #expect(try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .replace)
            == ItemCopyResultModel(replaced: 1))
        #expect(try harness.reveal(target) == ConfigFixture.valueA)
        #expect(try harness.record(target).linkID != nil)
        #expect(try harness.record(target).linkID == harness.record(source).linkID)
    }

    @Test func copyingACopyJoinsTheSameGroupAndTheTableCountsIt() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let repoB = try harness.seedRepository(name: "repo-b")
        let staging = try harness.config.createEnvironment(in: repoA.id, name: "staging")
        let source = try harness.add(repoA, "API_KEY", value: ConfigFixture.valueA)
        try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)
        let copy = try #require(try harness.store.fetchItemRecords(repositoryID: repoB.id).first)

        try harness.config.copyItems([copy.id], to: .environment(staging), repositoryID: repoA.id, conflicts: .keep)

        let link = try #require(try harness.record(source).linkID)
        let third = try #require(try harness.store.fetchItemRecords(repositoryID: repoA.id, scope: .environment(staging)).first)
        #expect(third.linkID == link)
        let models = try await Self.firstItems(harness, repoA, scope: .repository)
        #expect(models.map(\.linkCount) == [3])
        #expect(models.first?.isLinked == true)
        let unlinked = try harness.add(repoA, "OTHER", value: ConfigFixture.valueC)
        let after = try await Self.firstItems(harness, repoA, scope: .repository)
        #expect(after.first { $0.id == unlinked }?.linkCount == 0)
        #expect(after.first { $0.id == unlinked }?.isLinked == false)
    }

    @Test func aDeletedCopyLeavesTheCount() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let repoB = try harness.seedRepository(name: "repo-b")
        let source = try harness.add(repoA, "API_KEY", value: ConfigFixture.valueA)
        try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)
        let copy = try #require(try harness.store.fetchItemRecords(repositoryID: repoB.id).first)
        try harness.markSynced(repoB)

        try harness.config.deleteItem(copy.id)

        #expect(try await Self.firstItems(harness, repoA, scope: .repository).first?.linkCount == 1)
        #expect(try harness.config.linkedCopies(of: source).isEmpty)
    }

    // MARK: - Links follow the item (L2)

    @Test func moveAndRenameKeepTheLink() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let repoB = try harness.seedRepository(name: "repo-b")
        let staging = try harness.config.createEnvironment(in: repoB.id, name: "staging")
        let source = try harness.add(repoA, "API_KEY", value: ConfigFixture.valueA)
        try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)
        let copy = try #require(try harness.store.fetchItemRecords(repositoryID: repoB.id).first)
        let link = try #require(copy.linkID)
        try harness.markSynced(repoB)

        let moved = try harness.config.moveItem(copy.id, toKind: .secret, scope: .environment(staging))
        #expect(moved != copy.id)
        #expect(try harness.record(moved).linkID == link)
        let renamed = try harness.config.renameItem(moved, to: "API_TOKEN")
        #expect(try harness.record(renamed).linkID == link)
    }

    // MARK: - Linked copies (L3)

    @Test func linkedCopiesListTheOtherPlacesWithTheirComparison() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let repoB = try harness.seedRepository(name: "repo-b")
        let staging = try harness.config.createEnvironment(in: repoA.id, name: "staging")
        let source = try harness.add(repoA, "API_KEY", value: ConfigFixture.valueA)
        try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)
        try harness.config.copyItems([source], to: .environment(staging), repositoryID: repoA.id, conflicts: .keep)
        let inB = try #require(try harness.store.fetchItemRecords(repositoryID: repoB.id).first)
        try harness.config.editValue(inB.id, value: SecretBytes(utf8: ConfigFixture.valueB))

        let copies = try harness.config.linkedCopies(of: source)

        #expect(copies.map(\.repositoryFullName) == ["owner-a/repo-a", "owner-a/repo-b"])
        let inStaging = try #require(copies.first)
        #expect(inStaging.environmentName == "staging")
        #expect(inStaging.scope == .environment(staging))
        #expect(inStaging.comparison == .same)
        #expect(inStaging.accountLogin == ConfigFixture.login)
        #expect(inStaging.syncStatus == .added)
        #expect(inStaging.isEditable)
        let other = try #require(copies.last)
        #expect(other.itemID == inB.id)
        #expect(other.environmentName == nil)
        #expect(other.comparison == .differs)
        #expect(try harness.config.linkedCopies(of: inB.id).map(\.comparison) == [.differs, .differs])
    }

    @Test func linkedCopiesReportMissingValuesAndReadOnlyPlaces() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let repoB = try harness.seedRepository(name: "repo-b")
        let source = try harness.add(repoA, "API_KEY", value: ConfigFixture.valueA)
        try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)
        var copy = try #require(try harness.store.fetchItemRecords(repositoryID: repoB.id).first)
        copy.valueCiphertext = nil
        copy.valueFingerprint = nil
        try harness.store.updateItem(copy)
        var readOnly = repoB
        readOnly.hasAdmin = false
        readOnly.hasPush = false
        try RepoStore(database: harness.database).update(readOnly)

        let listed = try #require(try harness.config.linkedCopies(of: source).first)
        #expect(listed.comparison == .valueMissing)
        #expect(listed.editBlock == .readOnly(.adminRequired))
        #expect(!listed.isEditable)
        #expect(try harness.config.linkedCopies(of: copy.id).first?.comparison == .unknown)
    }

    // MARK: - Unlink (L3)

    @Test func unlinkTakesTheItemOutAndClearsALastPartner() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let repoB = try harness.seedRepository(name: "repo-b")
        let repoC = try harness.seedRepository(name: "repo-c")
        let source = try harness.add(repoA, "API_KEY", value: ConfigFixture.valueA)
        try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)
        try harness.config.copyItems([source], to: .repository, repositoryID: repoC.id, conflicts: .keep)
        let inB = try #require(try harness.store.fetchItemRecords(repositoryID: repoB.id).first)
        let inC = try #require(try harness.store.fetchItemRecords(repositoryID: repoC.id).first)
        let link = try #require(inB.linkID)

        try harness.config.unlink(inB.id)
        #expect(try harness.record(inB.id).linkID == nil)
        #expect(try harness.record(source).linkID == link, "two places are still linked")
        #expect(try harness.status(inB.id) == .added, "nothing else changes")

        try harness.config.unlink(inC.id)
        #expect(try harness.record(inC.id).linkID == nil)
        #expect(try harness.record(source).linkID == nil, "a group of one is no group")
        try harness.config.unlink(source)
    }

    // MARK: - Update everywhere (L4)

    @Test func updateLinkedCopiesMakesEveryTargetAPendingChange() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let repoB = try harness.seedRepository(name: "repo-b")
        let staging = try harness.config.createEnvironment(in: repoA.id, name: "staging")
        let source = try harness.add(repoA, "API_KEY", value: ConfigFixture.valueA)
        try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)
        try harness.config.copyItems([source], to: .environment(staging), repositoryID: repoA.id, conflicts: .keep)
        try harness.markSynced(repoA)
        try harness.markSynced(repoB)
        let targets = try harness.config.linkedCopies(of: source).map(\.itemID)
        try harness.config.editValue(source, value: SecretBytes(utf8: ConfigFixture.valueC))

        #expect(try harness.config.updateLinkedCopies(from: source, to: targets) == 2)

        for target in targets {
            #expect(try harness.reveal(target) == ConfigFixture.valueC)
            #expect(try harness.status(target) == .modified)
        }
        #expect(try harness.config.linkedCopies(of: source).map(\.comparison) == [.same, .same])
    }

    @Test func updateLinkedCopiesFillsAValueMissingSecretWithAPush() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let repoB = try harness.seedRepository(name: "repo-b")
        let source = try harness.add(repoA, "API_KEY", value: ConfigFixture.valueA)
        try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)
        try harness.markSynced(repoB)
        var copy = try #require(try harness.store.fetchItemRecords(repositoryID: repoB.id).first)
        copy.valueCiphertext = nil
        copy.valueFingerprint = nil
        copy.syncedValueCiphertext = nil
        try harness.store.updateItem(copy)

        try harness.config.updateLinkedCopies(from: source, to: [copy.id])

        #expect(try harness.reveal(copy.id) == ConfigFixture.valueA)
        let filled = try harness.record(copy.id)
        #expect(filled.forcePush)
        #expect(filled.forcePushRequestedAt == harness.clock.now)
    }

    @Test func updateLinkedCopiesWritesNothingWhenOneTargetIsReadOnly() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let repoB = try harness.seedRepository(name: "repo-b")
        let repoC = try harness.seedRepository(name: "repo-c")
        let source = try harness.add(repoA, "API_KEY", value: ConfigFixture.valueA)
        try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)
        try harness.config.copyItems([source], to: .repository, repositoryID: repoC.id, conflicts: .keep)
        let inB = try #require(try harness.store.fetchItemRecords(repositoryID: repoB.id).first)
        let inC = try #require(try harness.store.fetchItemRecords(repositoryID: repoC.id).first)
        var readOnly = repoC
        readOnly.hasAdmin = false
        readOnly.hasPush = false
        try RepoStore(database: harness.database).update(readOnly)
        try harness.config.editValue(source, value: SecretBytes(utf8: ConfigFixture.valueC))

        #expect(configError { try harness.config.updateLinkedCopies(from: source, to: [inB.id, inC.id]) }
            == .readOnly(.adminRequired))
        #expect(try harness.reveal(inB.id) == ConfigFixture.valueA)
        #expect(try harness.reveal(inC.id) == ConfigFixture.valueA)
    }

    @Test func updateLinkedCopiesRefusesAnItemOutsideTheGroup() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let repoB = try harness.seedRepository(name: "repo-b")
        let source = try harness.add(repoA, "API_KEY", value: ConfigFixture.valueA)
        try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)
        let stranger = try harness.add(repoB, "OTHER", value: ConfigFixture.valueB)

        #expect(configError { try harness.config.updateLinkedCopies(from: source, to: [stranger]) } == .itemNotFound)
        #expect(try harness.reveal(stranger) == ConfigFixture.valueB)
        #expect(try harness.config.updateLinkedCopies(from: source, to: []) == 0)
    }

    // MARK: - Links stay local (L5)

    @Test func duplicateEnvironmentDoesNotLink() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let staging = try harness.config.createEnvironment(in: repoA.id, name: "staging")
        try harness.add(repoA, "API_KEY", value: ConfigFixture.valueA, scope: .environment(staging))

        let qa = try harness.config.duplicateEnvironment(staging, as: "qa")

        #expect(try harness.store.fetchItemRecords(repositoryID: repoA.id).allSatisfy { $0.linkID == nil })
        #expect(try harness.store.fetchItemRecords(repositoryID: repoA.id, scope: .environment(qa)).count == 1)
    }

    // MARK: - Helpers

    /// A repository of another account (`login`), administered by the viewer.
    private static func seedRepository(_ harness: ConfigHarness, login: String, name: String) throws -> RepoModel {
        let start = ManualClock.defaultStart
        try AccountStore(database: harness.database).save(AccountModel(login: login, lastSeenAt: start))
        let repo = RepoModel(
            accountLogin: login,
            githubID: "R_\(name)",
            ownerLogin: login,
            ownerType: .user,
            name: name,
            visibility: .private,
            hasAdmin: true,
            hasPush: true,
            origin: .imported,
            importedAt: start
        )
        try RepoStore(database: harness.database).insert(repo)
        return repo
    }

    /// The first value of the table's observation of one scope.
    private static func firstItems(_ harness: ConfigHarness, _ repo: RepoModel, scope: ConfigScope) async throws
        -> [ConfigItemModel]
    {
        for try await items in harness.config.observeItems(repositoryID: repo.id, scope: scope) {
            return items
        }
        return []
    }
}
