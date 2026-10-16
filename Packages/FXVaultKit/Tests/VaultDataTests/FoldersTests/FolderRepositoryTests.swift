import EnvTools
import Foundation
import SyncEngine
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Folders (v0.7.0, tasks/todo.md F1–F6): folder names and order, items with their own field
/// AAD, copy and paste in every direction with links, linked updates across folders and
/// repositories, `.env` import and export, DEK rotation, and that no sync input ever sees a
/// folder.
@Suite("FolderRepository")
struct FolderRepositoryTests {
    struct Fixture {
        let harness: ConfigHarness
        let folders: FolderRepository

        static func make() async throws -> Fixture {
            let harness = try await ConfigHarness.make()
            return Fixture(harness: harness, folders: FolderRepository(session: harness.session, clock: harness.clock))
        }

        var config: ConfigRepository {
            harness.config
        }

        var store: FolderStore {
            FolderStore(database: harness.database)
        }

        @discardableResult
        func add(_ folder: FolderID, _ name: String, kind: ConfigKind = .secret, value: String) throws -> ConfigItemID {
            try folders.addItem(folderID: folder, kind: kind, name: name, value: SecretBytes(utf8: value)).itemID
        }

        func reveal(_ id: ConfigItemID) throws -> String? {
            let value = try folders.reveal(id)
            defer { value.wipe() }
            return value.utf8String()
        }

        func record(_ id: ConfigItemID) throws -> FolderItemRecord {
            try #require(try store.fetchItemRecord(id: id))
        }
    }

    // MARK: - Folders (F1, F3)

    @Test func foldersAreCreatedInOrderWithUniqueNames() async throws {
        let fixture = try await Fixture.make()
        let mobile = try fixture.folders.createFolder(named: "Mobile App")
        let firebase = try fixture.folders.createFolder(named: "Firebase · test")

        #expect(try fixture.folders.folders().map(\.name) == ["Mobile App", "Firebase · test"])
        #expect(configError { try fixture.folders.createFolder(named: "mobile app") } == .validation(.duplicateName))
        #expect(configError { try fixture.folders.createFolder(named: " Mobile") } == .validation(.invalidName(.leadingOrTrailingWhitespace)))
        #expect(configError { try fixture.folders.createFolder(named: "") } == .validation(.invalidName(.empty)))
        let tooLong = String(repeating: "a", count: Limits.maxFolderNameLength + 1)
        #expect(configError { try fixture.folders.createFolder(named: tooLong) }
            == .validation(.invalidName(.tooLong(maxLength: Limits.maxFolderNameLength))))

        try fixture.folders.renameFolder(mobile, to: "MOBILE APP")
        #expect(configError { try fixture.folders.renameFolder(firebase, to: "Mobile app") } == .validation(.duplicateName))
        try fixture.folders.reorderFolders([firebase, mobile])
        #expect(try fixture.folders.folders().map(\.name) == ["Firebase · test", "MOBILE APP"])
        #expect(configError { try fixture.folders.reorderFolders([mobile]) } == .folderNotFound)

        try fixture.folders.deleteFolder(firebase)
        #expect(try fixture.folders.folders().map(\.id) == [mobile])
        #expect(configError { try fixture.folders.deleteFolder(firebase) } == .folderNotFound)
    }

    @Test func folderObservationCountsItemsByKind() async throws {
        let fixture = try await Fixture.make()
        let folder = try fixture.folders.createFolder(named: "Mobile App")
        try fixture.add(folder, "API_KEY", value: ConfigFixture.valueA)
        try fixture.add(folder, "API_URL", kind: .variable, value: ConfigFixture.valueB)
        try fixture.add(folder, "SENTRY_DSN", value: ConfigFixture.valueC)

        var iterator = fixture.folders.observeFolders().makeAsyncIterator()
        let first = try #require(try await iterator.next()?.first)
        #expect(first.secretCount == 2)
        #expect(first.variableCount == 1)
        #expect(first.itemCount == 3)
    }

    // MARK: - Items (F2, F4)

    @Test func itemsFollowGitHubNamesAndAreSealedForTheirIdentity() async throws {
        let fixture = try await Fixture.make()
        let folder = try fixture.folders.createFolder(named: "Mobile App")
        let id = try fixture.folders.addItem(
            folderID: folder,
            kind: .secret,
            name: "api_key",
            value: SecretBytes(utf8: ConfigFixture.valueA + "\r\n")
        )

        #expect(id.didStripTrailingNewlines)
        #expect(try fixture.record(id.itemID).name == "API_KEY")
        #expect(try fixture.reveal(id.itemID) == ConfigFixture.valueA)
        #expect(configError { try fixture.add(folder, "API_KEY", value: ConfigFixture.valueB) } == .validation(.duplicateName))
        try fixture.add(folder, "API_KEY", kind: .variable, value: ConfigFixture.valueB)
        #expect(configError { try fixture.add(folder, "GITHUB_TOKEN", value: ConfigFixture.valueB) } == .validation(.invalidName(.reservedPrefix)))
        #expect(configError { try fixture.add(folder, "EMPTY", value: "") } == .validation(.emptyValue))

        // Rename and kind change re-seal the value; the blob no longer opens under the old identity.
        let before = try fixture.record(id.itemID)
        try fixture.folders.editItem(id.itemID, name: "API_SECRET", kind: .secret, value: nil)
        let renamed = try fixture.record(id.itemID)
        #expect(renamed.valueCiphertext != before.valueCiphertext)
        #expect(try fixture.reveal(id.itemID) == ConfigFixture.valueA)
        let staleAAD = FolderFieldAAD(rowID: id.itemID, folderID: folder, kind: .secret, name: "API_KEY")
        #expect(throws: VaultError.self) {
            try fixture.harness.session.read { keys, _ in try keys.open(renamed.valueCiphertext, for: staleAAD) }
        }
        try fixture.folders.editItem(id.itemID, name: "API_SECRET", kind: .variable, value: SecretBytes(utf8: ConfigFixture.valueC))
        #expect(try fixture.record(id.itemID).kind == .variable)
        #expect(try fixture.reveal(id.itemID) == ConfigFixture.valueC)
        #expect(configError { try fixture.folders.editItem(id.itemID, name: "API_KEY", kind: .variable, value: nil) }
            == .validation(.duplicateName))

        try fixture.folders.deleteItems([id.itemID])
        #expect(try fixture.folders.items(folderID: folder).map(\.name) == ["API_KEY"])
    }

    @Test func aFullFolderRefusesAnotherItem() async throws {
        let fixture = try await Fixture.make()
        let folder = try fixture.folders.createFolder(named: "Full")
        let now = fixture.harness.clock.now
        try fixture.harness.database.write { tx in
            for index in 0..<Limits.maxFolderItems {
                try fixture.store.insertItem(FolderItemRecord(
                    folderID: folder,
                    kind: .variable,
                    name: "ITEM_\(index)",
                    valueCiphertext: Data([1]),
                    valueFingerprint: Data([2]),
                    createdAt: now,
                    updatedAt: now
                ), in: tx)
            }
        }
        #expect(configError { try fixture.add(folder, "ONE_MORE", value: ConfigFixture.valueA) } == .folderFull(limit: Limits.maxFolderItems))
    }

    @Test func itemsNeedAnUnlockedVaultAndAnExistingFolder() async throws {
        let fixture = try await Fixture.make()
        let folder = try fixture.folders.createFolder(named: "Mobile App")
        #expect(configError { try fixture.add(FolderID(), "API_KEY", value: ConfigFixture.valueA) } == .folderNotFound)
        fixture.harness.manager.lock()
        #expect(configError { try fixture.add(folder, "API_KEY", value: ConfigFixture.valueA) } == .vault(.locked))
    }

    // MARK: - Copy and paste (F5)

    @Test func copiesFromARepositoryIntoAFolderAndBackAreLinked() async throws {
        let fixture = try await Fixture.make()
        let repoA = try fixture.harness.seedRepository()
        let repoB = try fixture.harness.seedRepository(name: "repo-b")
        let folder = try fixture.folders.createFolder(named: "Mobile App")
        let source = try fixture.harness.add(repoA, "API_KEY", value: ConfigFixture.valueA)

        #expect(try fixture.folders.copyConflicts([source], to: folder).isEmpty)
        #expect(try fixture.folders.copyItems([source], to: folder, conflicts: .keep) == ItemCopyResultModel(added: 1))
        let inFolder = try #require(try fixture.folders.items(folderID: folder).first)
        #expect(try fixture.reveal(inFolder.id) == ConfigFixture.valueA)
        let link = try #require(try fixture.harness.record(source).linkID)
        #expect(inFolder.linkID == link)
        #expect(inFolder.linkCount == 2)

        // Folder → another repository: a pending add in the same group.
        #expect(try fixture.config.copyConflicts([inFolder.id], to: .repository, repositoryID: repoB.id).isEmpty)
        #expect(try fixture.config.copyItems([inFolder.id], to: .repository, repositoryID: repoB.id, conflicts: .keep)
            == ItemCopyResultModel(added: 1))
        let inB = try #require(try fixture.harness.store.fetchItemRecords(repositoryID: repoB.id).first)
        #expect(inB.linkID == link)
        #expect(try fixture.harness.status(inB.id) == .added)
        #expect(try fixture.harness.reveal(inB.id) == ConfigFixture.valueA)
        #expect(try fixture.folders.items(folderID: folder).first?.linkCount == 3)

        // Copying into the folder it is already in does nothing.
        #expect(try fixture.folders.copyItems([inFolder.id], to: folder, conflicts: .keep) == ItemCopyResultModel())
    }

    @Test func folderToFolderAndConflictsReplaceOrKeep() async throws {
        let fixture = try await Fixture.make()
        let mobile = try fixture.folders.createFolder(named: "Mobile App")
        let web = try fixture.folders.createFolder(named: "Web")
        let source = try fixture.add(mobile, "API_KEY", value: ConfigFixture.valueA)
        let existing = try fixture.add(web, "api_key", value: ConfigFixture.valueB)

        #expect(try fixture.folders.copyConflicts([source], to: web) == ["API_KEY"])
        #expect(try fixture.folders.copyItems([source], to: web, conflicts: .keep) == ItemCopyResultModel(kept: 1))
        #expect(try fixture.record(existing).linkID == nil)
        #expect(try fixture.folders.copyItems([source], to: web, conflicts: .replace) == ItemCopyResultModel(replaced: 1))
        #expect(try fixture.reveal(existing) == ConfigFixture.valueA)
        #expect(try fixture.record(existing).linkID == fixture.record(source).linkID)
    }

    @Test func aValueMissingRepositorySecretIsNotCopiedIntoAFolder() async throws {
        let fixture = try await Fixture.make()
        let repo = try fixture.harness.seedRepository()
        let folder = try fixture.folders.createFolder(named: "Mobile App")
        let source = try fixture.harness.add(repo, "IMPORTED", value: ConfigFixture.valueA)
        var record = try fixture.harness.record(source)
        record.valueCiphertext = nil
        record.valueFingerprint = nil
        try fixture.harness.store.updateItem(record)

        #expect(try fixture.folders.copyItems([source], to: folder, conflicts: .keep) == ItemCopyResultModel(withoutValue: ["IMPORTED"]))
        #expect(try fixture.folders.items(folderID: folder).isEmpty)
    }

    // MARK: - Linked copies across folders and repositories (F6)

    @Test func rotatingInTheFolderUpdatesItsRepositoryCopies() async throws {
        let fixture = try await Fixture.make()
        let repoA = try fixture.harness.seedRepository()
        let repoB = try fixture.harness.seedRepository(name: "repo-b")
        let mobile = try fixture.folders.createFolder(named: "Mobile App")
        let web = try fixture.folders.createFolder(named: "Web")
        let source = try fixture.add(mobile, "API_KEY", value: ConfigFixture.valueA)
        try fixture.config.copyItems([source], to: .repository, repositoryID: repoA.id, conflicts: .keep)
        try fixture.config.copyItems([source], to: .repository, repositoryID: repoB.id, conflicts: .keep)
        try fixture.folders.copyItems([source], to: web, conflicts: .keep)
        let inA = try #require(try fixture.harness.store.fetchItemRecords(repositoryID: repoA.id).first)
        let inB = try #require(try fixture.harness.store.fetchItemRecords(repositoryID: repoB.id).first)
        let inWeb = try #require(try fixture.folders.items(folderID: web).first)
        try fixture.harness.markSynced(repoA)
        try fixture.config.editValue(inB.id, value: SecretBytes(utf8: ConfigFixture.valueB))

        let copies = try fixture.config.linkedCopies(of: source)
        #expect(copies.map(\.placeName) == ["Web", "owner-a/repo-a", "owner-a/repo-b"])
        #expect(copies.first?.place == .folder(web, name: "Web"))
        #expect(copies.first?.itemPlace == .folder(web))
        #expect(copies.first?.syncStatus == nil)
        #expect(copies.map(\.comparison) == [.same, .same, .differs])
        #expect(try fixture.config.linkedCopies(of: inA.id).map(\.placeName) == ["Mobile App", "Web", "owner-a/repo-b"])

        try fixture.folders.editItem(source, name: "API_KEY", kind: .secret, value: SecretBytes(utf8: ConfigFixture.valueC))
        #expect(try fixture.config.updateLinkedCopies(from: source, to: [inA.id, inWeb.id]) == 2)
        #expect(try fixture.harness.reveal(inA.id) == ConfigFixture.valueC)
        #expect(try fixture.harness.status(inA.id) == .modified)
        #expect(try fixture.reveal(inWeb.id) == ConfigFixture.valueC)
        #expect(try fixture.harness.reveal(inB.id) == ConfigFixture.valueB, "an unchecked copy keeps its value")

        // From a repository copy to a folder copy as well.
        try fixture.config.editValue(inB.id, value: SecretBytes(utf8: ConfigFixture.valueA))
        #expect(try fixture.config.updateLinkedCopies(from: inB.id, to: [source]) == 1)
        #expect(try fixture.reveal(source) == ConfigFixture.valueA)
    }

    @Test func unlinkAndDeletingAFolderLeaveTheRepositoryCopies() async throws {
        let fixture = try await Fixture.make()
        let repo = try fixture.harness.seedRepository()
        let folder = try fixture.folders.createFolder(named: "Mobile App")
        let source = try fixture.add(folder, "API_KEY", value: ConfigFixture.valueA)
        let other = try fixture.add(folder, "API_URL", kind: .variable, value: ConfigFixture.valueB)
        try fixture.config.copyItems([source, other], to: .repository, repositoryID: repo.id, conflicts: .keep)
        let copies = try fixture.harness.store.fetchItemRecords(repositoryID: repo.id)
        #expect(copies.count == 2)

        try fixture.config.unlink(source)
        #expect(try fixture.record(source).linkID == nil)
        let keyCopy = try #require(copies.first { $0.name == "API_KEY" })
        #expect(try fixture.harness.record(keyCopy.id).linkID == nil, "the last one left is unlinked too")

        try fixture.folders.deleteFolder(folder)
        let after = try fixture.harness.store.fetchItemRecords(repositoryID: repo.id)
        #expect(after.map(\.name) == ["API_KEY", "API_URL"])
        let urlCopy = try #require(after.first { $0.name == "API_URL" })
        #expect(try fixture.config.linkedCopies(of: urlCopy.id).isEmpty)
    }

    // MARK: - .env import and export

    @Test func envImportIntoAFolderAndExportFromIt() async throws {
        let fixture = try await Fixture.make()
        let folder = try fixture.folders.createFolder(named: "Mobile App")
        try fixture.add(folder, "API_KEY", value: ConfigFixture.valueB)
        let directory = try ConfigTempDirectory()
        defer { directory.remove() }
        let files = EnvFileRepository(
            session: fixture.harness.session,
            gitignoreChecker: StubGitignoreChecker(),
            cloudSyncDetector: CloudSyncDetector(homeDirectory: directory.url, isUbiquitous: { _ in false }),
            clock: fixture.harness.clock
        )
        let contents = SecretBytes(utf8: "API_KEY=fixture-a\nAPI_URL=https://api.example.invalid\n")
        defer { contents.wipe() }
        let preview = try files.parse(contents)
        defer { preview.wipe() }
        let selections = preview.defaultSelections.map {
            EnvImportSelectionModel(candidateIndex: $0.candidateIndex, name: $0.name, kind: .secret, onConflict: .skip)
        }

        #expect(try files.conflictingCandidates(for: selections, in: preview, place: .folder(folder)) == [0])
        let skipped = try files.applyImport(preview, selections: selections, place: .folder(folder))
        #expect(skipped.added == ["API_URL"])
        #expect(skipped.skipped.map(\.reason) == [.existingItem])
        let overwrite = selections.map {
            EnvImportSelectionModel(candidateIndex: $0.candidateIndex, name: $0.name, kind: $0.kind, onConflict: .overwrite)
        }
        #expect(try files.applyImport(preview, selections: overwrite, place: .folder(folder)).overwritten == ["API_KEY", "API_URL"])

        #expect(try files.exportPreview(place: .folder(folder)).exportedNames == ["API_KEY", "API_URL"])
        let authorization = try await ReauthGate(manager: fixture.harness.manager).authorizeEnvExport(
            with: .password(ConfigFixture.password),
            session: fixture.harness.session
        )
        let url = directory.file("mobile.env")
        try files.export(place: .folder(folder), to: url, authorization: authorization)
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("API_KEY=fixture-a"))
        #expect(written.contains("API_URL=https://api.example.invalid"))
    }

    // MARK: - Keys and sync isolation

    @Test func dekRotationReSealsFolderValues() async throws {
        let fixture = try await Fixture.make()
        let folder = try fixture.folders.createFolder(named: "Mobile App")
        let id = try fixture.add(folder, "API_KEY", value: ConfigFixture.valueA)
        let before = try fixture.record(id)

        _ = try await fixture.harness.manager.rotateDEK(password: ConfigFixture.password)

        let after = try fixture.record(id)
        #expect(after.valueCiphertext != before.valueCiphertext)
        #expect(after.valueFingerprint != before.valueFingerprint)
        #expect(try fixture.reveal(id) == ConfigFixture.valueA)
    }

    @Test func noSyncInputSeesAFolderItem() async throws {
        let fixture = try await Fixture.make()
        let repo = try fixture.harness.seedRepository()
        try fixture.harness.add(repo, "API_KEY", value: ConfigFixture.valueA)
        try fixture.harness.markSynced(repo)
        let before = try fixture.harness.changeSet(repo)
        let folder = try fixture.folders.createFolder(named: "Mobile App")
        try fixture.add(folder, "API_KEY", value: ConfigFixture.valueB)
        try fixture.add(folder, "NEW_ITEM", value: ConfigFixture.valueC)

        #expect(try fixture.harness.changeSet(repo) == before)
        #expect(try fixture.config.pendingCounts().repositories[repo.id]?.pending == 0)
        #expect(try fixture.harness.store.fetchItemRecords(repositoryID: repo.id).map(\.name) == ["API_KEY"])
    }
}
