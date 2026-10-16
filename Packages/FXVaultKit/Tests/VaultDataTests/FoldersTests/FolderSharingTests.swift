import Foundation
import SharingKit
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// Sending a copy of a folder (v0.7.0, tasks/todo.md F7) through a `.fxvault` file: the folder
/// package, "Save as Folder" (new, or merged with Replace / Keep), the replay note and
/// "Import Into…" a repository scope through the usual import preview.
@Suite("Folder sharing")
struct FolderSharingTests {
    /// The sender's "Mobile App" folder with one secret and one variable.
    static func mobileFolder(in world: ShareWorld) throws -> FolderID {
        let folders = FolderRepository(session: world.sender.session, clock: world.sender.clock)
        let id = try folders.createFolder(named: "Mobile App")
        try folders.addItem(folderID: id, kind: .secret, name: "API_KEY", value: SecretBytes(utf8: "folder-secret"))
        try folders.addItem(folderID: id, kind: .variable, name: "API_URL", value: SecretBytes(utf8: "https://api.example.invalid"))
        return id
    }

    static func openFolder(_ world: ShareWorld, file: URL, passphrase: String) async throws -> ShareFolderDraftModel {
        let opened = try await world.receiverSharing.openFileContents(
            world.receiverSharing.readFile(at: file),
            passphrase: passphrase,
            checkGitHub: false
        )
        guard case .folder(let draft) = opened else {
            Issue.record("expected a folder")
            throw SharingError.unexpected
        }
        return draft
    }

    @Test func aFolderFileIsSavedAsANewFolderOrMergedIntoOne() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let source = try Self.mobileFolder(in: world)
        let preview = try await world.senderSharing.previewExport(.folder(source))
        #expect(preview.scope == .folder)
        #expect(preview.folderName == "Mobile App")
        #expect(preview.repositoryFullName.isEmpty)
        #expect(preview.itemCount == 2)
        let (file, passphrase) = try await world.export(.folder(source), name: "mobile.fxvault")

        let draft = try await Self.openFolder(world, file: file, passphrase: passphrase)
        #expect(draft.folderName == "Mobile App")
        #expect(!draft.wasImported)
        #expect(draft.manifest.flattenedItems.map(\.item.name) == ["API_KEY", "API_URL"])
        #expect(draft.manifest.flattenedItems.allSatisfy { $0.item.value == nil })
        // The repository-only open refuses a folder.
        await #expect(throws: SharingError.share(.invalidPackage(.scopeMismatch(.folder)))) {
            _ = try await world.open(file, passphrase: passphrase)
        }

        let saved = try await world.receiverSharing.saveFolder(draft, as: .newFolder(name: draft.folderName), conflicts: .keep)
        #expect(saved.items == ItemCopyResultModel(added: 2))
        #expect(draft.isClosed)
        let receiverFolders = FolderRepository(session: world.receiver.session, clock: world.receiver.clock)
        let items = try receiverFolders.items(folderID: saved.folderID)
        #expect(items.map(\.name) == ["API_KEY", "API_URL"])
        let secret = try receiverFolders.reveal(try #require(items.first).id)
        defer { secret.wipe() }
        #expect(secret.utf8String() == "folder-secret")
        await #expect(throws: SharingError.draftClosed) {
            _ = try await world.receiverSharing.saveFolder(draft, as: .existing(saved.folderID), conflicts: .keep)
        }

        // The same file again: noted as imported; a new folder of that name is refused; merged.
        let again = try await Self.openFolder(world, file: file, passphrase: passphrase)
        #expect(again.wasImported)
        await #expect(throws: SharingError.config(.validation(.duplicateName))) {
            _ = try await world.receiverSharing.saveFolder(again, as: .newFolder(name: "mobile app"), conflicts: .keep)
        }
        let kept = try await world.receiverSharing.saveFolder(again, as: .existing(saved.folderID), conflicts: .keep)
        #expect(kept.items == ItemCopyResultModel(kept: 2))
        let third = try await Self.openFolder(world, file: file, passphrase: passphrase)
        let replaced = try await world.receiverSharing.saveFolder(third, as: .existing(saved.folderID), conflicts: .replace)
        #expect(replaced.items == ItemCopyResultModel(replaced: 2))
    }

    @Test func aFolderFileIsImportedIntoARepositoryEnvironment() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let source = try Self.mobileFolder(in: world)
        let (file, passphrase) = try await world.export(.folder(source))
        let draft = try await Self.openFolder(world, file: file, passphrase: passphrase)
        let repository = try world.receiver.repository()
        let production = try #require(try world.receiver.environment("production"))

        let imported = try await world.receiverSharing.importDraft(draft, into: repository.id, scope: .environment(production.id), checkGitHub: false)
        #expect(draft.isClosed)
        #expect(imported.package.repository.fullName == repository.fullName)
        #expect(imported.plan.blockReason == nil)
        let result = try await world.receiverSharing.apply(imported, plan: imported.plan, confirmReplay: false)
        #expect(Set(result.added) == ["production/API_KEY", "production/API_URL"])
        let copy = try #require(try world.receiver.item("API_KEY", kind: .secret, scope: .environment(production.id)))
        #expect(try world.receiver.value(copy.id) == "folder-secret")
        #expect(copy.provenance == .share)
    }
}
