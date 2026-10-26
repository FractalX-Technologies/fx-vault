import Foundation
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// The notes' Review saves a folder's edits in one transaction (1.0 N2). A folder never syncs, so
/// every edit is final.
@Suite("FolderRepository place edits")
struct FolderPlaceEditsTests {
    @Test func everyEditOfAFolderIsSavedTogether() async throws {
        let fixture = try await FolderRepositoryTests.Fixture.make()
        let folder = try fixture.folders.createFolder(named: "Mobile App")
        let renamed = try fixture.add(folder, "API_KEY", value: ConfigFixture.valueA)
        let variable = try fixture.add(folder, "LOG_LEVEL", kind: .variable, value: "info")
        let removed = try fixture.add(folder, "OLD_TOKEN", value: ConfigFixture.valueB)

        let edits = PlaceItemEditsModel(
            deletions: [removed],
            changes: [
                .init(id: renamed, name: "API_TOKEN", value: SecretBytes(utf8: ConfigFixture.valueC)),
                .init(id: variable, value: SecretBytes(utf8: "debug\n")),
            ],
            additions: [.init(kind: .variable, name: "FEATURE_FLAGS", value: SecretBytes(utf8: "beta,search"))]
        )
        defer { edits.wipe() }
        try fixture.folders.applyEdits(edits, folderID: folder)

        let items = try fixture.folders.items(folderID: folder)
        #expect(items.map(\.name).sorted() == ["API_TOKEN", "FEATURE_FLAGS", "LOG_LEVEL"])
        #expect(try fixture.reveal(renamed) == ConfigFixture.valueC)
        #expect(try fixture.reveal(variable) == "debug")
    }

    @Test func nothingIsWrittenWhenOneEditFails() async throws {
        let fixture = try await FolderRepositoryTests.Fixture.make()
        let folder = try fixture.folders.createFolder(named: "Mobile App")
        let removed = try fixture.add(folder, "OLD_TOKEN", value: ConfigFixture.valueA)

        let edits = PlaceItemEditsModel(
            deletions: [removed],
            additions: [.init(kind: .secret, name: "GITHUB_TOKEN", value: SecretBytes(utf8: ConfigFixture.valueB))]
        )
        defer { edits.wipe() }
        let error = configError { try fixture.folders.applyEdits(edits, folderID: folder) }

        #expect(error == .validation(.invalidName(.reservedPrefix)))
        #expect(try fixture.folders.items(folderID: folder).map(\.id) == [removed])
    }

    @Test func anItemOfAnotherFolderIsRefused() async throws {
        let fixture = try await FolderRepositoryTests.Fixture.make()
        let folder = try fixture.folders.createFolder(named: "Mobile App")
        let other = try fixture.folders.createFolder(named: "Web")
        let elsewhere = try fixture.add(other, "API_KEY", value: ConfigFixture.valueA)

        let error = configError { try fixture.folders.applyEdits(PlaceItemEditsModel(deletions: [elsewhere]), folderID: folder) }

        #expect(error == .itemNotFound)
        #expect(try fixture.folders.items(folderID: other).map(\.id) == [elsewhere])
    }
}
