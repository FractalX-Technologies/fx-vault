import Foundation
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// File secrets (1.0 F1): the file label (`file_detail`, v21) follows the value in the three item
/// tables. It is kept by a rename, a move, a copy and a linked update, and dropped by a new value.
@Suite("File secret items")
struct FileSecretItemTests {
    static let file = FileSecretModel(fileName: "AuthKey.p8", lineCount: 6, encoding: .text)

    // MARK: - Repositories and environments

    @Test func aRepositoryItemKeepsItsFileUntilItsValueChanges() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let id = try harness.config.addItem(
            repositoryID: repo.id, scope: .repository, kind: .secret, name: "APNS_KEY",
            value: SecretBytes(utf8: ConfigFixture.valueA), file: Self.file
        ).itemID
        #expect(try harness.record(id).file == Self.file)
        #expect(try harness.state(id).model.file == Self.file)

        let renamed = try harness.config.renameItem(id, to: "APNS_AUTH_KEY")
        #expect(try harness.record(renamed).file == Self.file)
        try harness.config.editValue(renamed, value: SecretBytes(utf8: ConfigFixture.valueA))
        #expect(try harness.record(renamed).file == Self.file)

        try harness.config.editValue(renamed, value: SecretBytes(utf8: ConfigFixture.valueB))
        #expect(try harness.record(renamed).file == nil)
    }

    @Test func aSyncedItemKeepsItsFileThroughARenameAndAMove() async throws {
        let harness = try await ConfigHarness.make()
        let repo = try harness.seedRepository()
        let production = try harness.config.createEnvironment(in: repo.id, name: "production")
        let id = try harness.config.addItem(
            repositoryID: repo.id, scope: .repository, kind: .secret, name: "APNS_KEY",
            value: SecretBytes(utf8: ConfigFixture.valueA), file: Self.file
        ).itemID
        try harness.markSynced(repo)

        let renamed = try harness.config.renameItem(id, to: "APNS_AUTH_KEY")
        #expect(try harness.record(renamed).file == Self.file)
        let moved = try harness.config.moveItem(renamed, toKind: .secret, scope: .environment(production))
        #expect(moved != renamed)
        #expect(try harness.record(moved).file == Self.file)
    }

    @Test func copiesAndLinkedUpdatesCarryTheFile() async throws {
        let harness = try await ConfigHarness.make()
        let repoA = try harness.seedRepository()
        let repoB = try harness.seedRepository(name: "repo-b")
        let source = try harness.config.addItem(
            repositoryID: repoA.id, scope: .repository, kind: .secret, name: "APNS_KEY",
            value: SecretBytes(utf8: ConfigFixture.valueA), file: Self.file
        ).itemID
        try harness.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)
        let copy = try #require(try harness.store.fetchItemRecords(repositoryID: repoB.id).first)
        #expect(copy.file == Self.file)

        // A typed value drops the copy's label; updating it from the source brings the file back.
        try harness.config.editValue(copy.id, value: SecretBytes(utf8: ConfigFixture.valueB))
        #expect(try harness.record(copy.id).file == nil)
        #expect(try harness.config.updateLinkedCopies(from: source, to: [copy.id]) == 1)
        #expect(try harness.record(copy.id).file == Self.file)
        #expect(try harness.reveal(copy.id) == ConfigFixture.valueA)
    }

    // MARK: - Folders

    @Test func aFolderItemKeepsItsFileUntilItsValueChanges() async throws {
        let fixture = try await FolderRepositoryTests.Fixture.make()
        let folder = try fixture.folders.createFolder(named: "Apple")
        let id = try fixture.folders.addItem(
            folderID: folder, kind: .secret, name: "APNS_KEY", value: SecretBytes(utf8: ConfigFixture.valueA), file: Self.file
        ).itemID
        #expect(try fixture.record(id).file == Self.file)

        try fixture.folders.editItem(id, name: "APNS_AUTH_KEY", kind: .secret, value: nil)
        #expect(try fixture.record(id).file == Self.file)
        try fixture.folders.editItem(id, name: "APNS_AUTH_KEY", kind: .secret, value: SecretBytes(utf8: ConfigFixture.valueB))
        #expect(try fixture.record(id).file == nil)
    }

    // MARK: - Destinations

    @Test func aDestinationItemKeepsItsFileThroughAPushedRename() async throws {
        let fixture = try await DestinationRepositoryTests.Fixture.make()
        let vault = try fixture.keyVault()
        let id = try fixture.destinations.addItem(
            destinationID: vault, kind: .secret, name: "APNS_KEY", value: SecretBytes(utf8: ConfigFixture.valueA), file: Self.file
        ).itemID
        #expect(try fixture.record(id).file == Self.file)
        try fixture.markSynced(vault)

        // Key Vault renames by deleting the old name and adding the new one: the label moves too.
        let renamed = try fixture.destinations.editItem(id, name: "APNS_AUTH_KEY", kind: .secret, value: nil).itemID
        #expect(renamed != id)
        #expect(try fixture.record(renamed).file == Self.file)

        try fixture.destinations.editItem(renamed, name: "APNS_AUTH_KEY", kind: .secret, value: SecretBytes(utf8: ConfigFixture.valueB))
        #expect(try fixture.record(renamed).file == nil)
    }

    @Test func aFolderItemCopiedToAKeyVaultKeepsItsFile() async throws {
        let fixture = try await DestinationRepositoryTests.Fixture.make()
        let folders = FolderRepository(session: fixture.harness.session, clock: fixture.harness.clock)
        let folder = try folders.createFolder(named: "Apple")
        let source = try folders.addItem(
            folderID: folder, kind: .secret, name: "APNS_KEY", value: SecretBytes(utf8: ConfigFixture.valueA), file: Self.file
        ).itemID
        let vault = try fixture.keyVault()

        #expect(try fixture.destinations.copyItems([source], to: vault, conflicts: .keep).added == 1)
        let copy = try #require(try fixture.destinations.items(destinationID: vault).first)
        #expect(copy.file == Self.file)
    }
}
