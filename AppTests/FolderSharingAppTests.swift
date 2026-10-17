import Foundation
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Sending a copy of a folder (v0.7.0, tasks/todo.md F7) and the sidebar (F3, N1): a `.fxvault`
/// folder saved as a folder or imported into a repository scope, a folder sent in Nearby Chat
/// and saved by the other Mac, Send Folder from a teammate, folder selection in the main window,
/// and the TEAMMATES rows.
@MainActor
@Suite("Folder sharing and the sidebar", .timeLimit(.minutes(1)))
struct FolderSharingAppTests {
    /// The sender's "Mobile App": FIREBASE_API_KEY and API_URL.
    static func mobileFolder(_ harness: TestHarness) throws -> FolderID {
        let folders = harness.data.folders
        let id = try folders.createFolder(named: "Mobile App")
        try folders.addItem(folderID: id, kind: .secret, name: "FIREBASE_API_KEY", value: SecretBytes(utf8: SharingWorld.secretValue))
        try folders.addItem(folderID: id, kind: .variable, name: "API_URL", value: SecretBytes(utf8: SharingWorld.variableValue))
        return id
    }

    private func openedFolder(_ world: SharingWorld) async throws -> ShareImportViewModel {
        let file = try await world.exportFile(.folder(try Self.mobileFolder(world.sender)))
        let model = ShareImportViewModel(context: ShareImportContext(fileURL: file.url), dependencies: world.receiverDependencies())
        await model.start()
        model.passphrase = file.passphrase
        await model.open()
        #expect(model.step == .folderDestination, "\(String(describing: model.passphraseError))")
        return model
    }

    // MARK: - A folder file

    @Test func aFolderFileIsSavedAsANewFolder() async throws {
        let world = try await SharingWorld()
        let model = try await openedFolder(world)
        let destination = try #require(model.destination)
        #expect(destination.senderFolderName == "Mobile App")
        #expect(destination.secretCount == 1 && destination.variableCount == 1)
        #expect(destination.folderChoice == .new)
        #expect(destination.newFolderName == "Mobile App")
        #expect(!model.wasFolderImported)
        #expect(model.canContinueFolder)

        await model.continueFolder()

        #expect(model.step == .folderSaved)
        #expect(model.folderNotice == "Saved 2 items in Mobile App.")
        let folder = try #require(try world.receiver.data.folders.folders().first)
        #expect(folder.name == "Mobile App" && folder.itemCount == 2)
        #expect(world.receiverRecorder.openedFolders == [folder.id])
    }

    @Test func aFolderOfTheSameNameIsPreselectedForMerging() async throws {
        let world = try await SharingWorld()
        let existing = try world.receiver.data.folders.createFolder(named: "MOBILE APP")
        try world.receiver.data.folders.addItem(folderID: existing, kind: .secret, name: "FIREBASE_API_KEY", value: SecretBytes(utf8: "mine"))
        let model = try await openedFolder(world)
        let destination = try #require(model.destination)
        #expect(destination.folderChoice == .existing(existing))
        #expect(destination.isMerging)
        destination.folderChoice = .new
        #expect(destination.newFolderNameNote == .error(FolderCopy.nameTaken))
        #expect(!model.canContinueFolder)
        destination.folderChoice = .existing(existing)

        await model.continueFolder()

        #expect(model.folderNotice == "Saved 1 item in MOBILE APP. Kept 1 that the folder already had.")
        let items = try world.receiver.data.folders.items(folderID: existing)
        #expect(items.map(\.name) == ["API_URL", "FIREBASE_API_KEY"])
        let kept = try world.receiver.data.folders.reveal(try #require(items.last).id)
        defer { kept.wipe() }
        #expect(kept.utf8String() == "mine")
    }

    @Test func aFolderFileIsImportedIntoARepositoryScope() async throws {
        let world = try await SharingWorld()
        let model = try await openedFolder(world)
        let destination = try #require(model.destination)
        destination.choice = .repository
        #expect(!model.canContinueFolder)
        destination.repositoryID = try #require(world.receiverRepositoryID)
        let production = try #require(destination.scopes.first { $0.environment?.name == SharingWorld.environment })
        destination.scope = production.scope
        #expect(model.canContinueFolder)

        await model.continueFolder()

        #expect(model.step == .preview)
        let editor = try #require(model.editor)
        #expect(editor.blockReason == nil)
        await model.apply()
        #expect(model.step == .done)
        #expect(Set(model.result?.added ?? []) == ["\(SharingWorld.environment)/FIREBASE_API_KEY", "\(SharingWorld.environment)/API_URL"])
    }

    // MARK: - Nearby Chat

    @Test func aFolderSentInChatIsSavedByTheOtherMac() async throws {
        let fixture = try await NearbyChatViewModelTests.Fixture()
        let folderID = try Self.mobileFolder(fixture.world.sender)
        try await fixture.chat()
        let macA = fixture.macA
        let macB = fixture.macB

        macA.attach(folder: folderID)
        let picker = try #require(macA.picker)
        #expect(picker.mode == .folder)
        #expect(picker.acceptsFolders)
        await picker.begin()
        picker.reauth.password = testPassword
        await picker.authenticateWithPassword()
        #expect(picker.selectedFolder?.name == "Mobile App")
        await picker.send()
        #expect(await TestFixtures.eventually { !macB.cards.isEmpty })
        let id = try #require(macB.cards.keys.first)
        let card = try #require(macB.cards[id])
        #expect(card.offer.folderName == "Mobile App")
        #expect(card.offer.isPackage)

        await macB.handleConfiguration(id, .importInto)
        #expect(await TestFixtures.eventually { macB.saveSheet != nil })
        let sheet = try #require(macB.saveSheet)
        #expect(sheet.isFolder)
        #expect(sheet.step == .choosingFolderDestination)
        await sheet.continueFolder()
        #expect(sheet.step == .folderSaved)
        let saved = try #require(try fixture.world.receiver.data.folders.folders().first)
        #expect(saved.name == "Mobile App" && saved.itemCount == 2)
        sheet.finish()
        #expect(await TestFixtures.eventually { macB.cards[id]?.status == .saved })
        fixture.close()
    }

    // MARK: - Send Folder from a teammate

    @Test func sendFolderOpensAChatThatAttachesIt() async throws {
        let (network, ana, ben) = try await TeamPresenceTests.pairedMacs()
        let folderID = try Self.mobileFolder(ana.harness)
        #expect(await TestFixtures.eventually { ana.person("Ben") != nil })
        let person = try #require(ana.person("Ben"))

        ana.presence.chat(with: person, sendingFolder: folderID)

        let start = try #require(ana.harness.app.takePendingChatStart())
        #expect(start.folderToSend == folderID)
        #expect(start.teammate != nil)
        start.transport.close()
        withExtendedLifetime((ben, network)) {}
    }

    // MARK: - Sidebar

    @Test func selectingAFolderReplacesTheRepositoryColumns() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        #expect(main.detail != nil)
        let folders = harness.data.folders
        let mobile = try folders.createFolder(named: "Mobile App")
        let stripe = try folders.createFolder(named: "Stripe test")
        #expect(await TestFixtures.eventually { main.sidebar.folders.map(\.name) == ["Mobile App", "Stripe test"] })
        let repositoryRow = main.sidebar.selectedRowID

        main.sidebar.selectedFolderID = mobile
        #expect(main.sidebar.selectedRowID == nil)
        #expect(main.folderDetail?.folderID == mobile)
        #expect(main.detail == nil && main.scopeList == nil)
        #expect(main.currentShareSelection == nil, "an empty folder has nothing to share")
        try folders.addItem(folderID: mobile, kind: .secret, name: "FIREBASE_API_KEY", value: SecretBytes(utf8: "v"))
        #expect(await TestFixtures.eventually { main.currentShareSelection == .folder(mobile) })
        #expect(main.canImportEnv)

        main.sidebar.searchText = "stripe"
        #expect(main.sidebar.visibleFolders.map(\.id) == [stripe])
        main.sidebar.searchText = ""
        main.sidebar.moveFolder(stripe, before: mobile)
        #expect(await TestFixtures.eventually { main.sidebar.folders.map(\.name) == ["Stripe test", "Mobile App"] })

        main.sidebar.selectedRowID = repositoryRow
        #expect(main.sidebar.selectedFolderID == nil)
        #expect(main.folderDetail == nil && main.detail != nil)

        main.sidebar.select(folderID: mobile)
        main.sidebar.pendingFolderDeletion = main.sidebar.folder(mobile)
        main.sidebar.confirmFolderDeletion()
        #expect(await TestFixtures.eventually { main.sidebar.selectedFolderID == nil && main.folderDetail == nil })

        main.newFolder()
        #expect(main.activeSheet == .folderName(FolderNameContext(mode: .create(itemIDs: []))))
        withExtendedLifetime(harness) {}
    }

    @Test func teammateRowsListNearbyTeammatesFirst() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func teammate(_ id: String, _ name: String) -> TeammateModel {
            TeammateModel(id: id, login: name.lowercased(), displayName: name, macName: "\(name)'s Mac", pairedAt: now)
        }
        let ana = teammate(String(repeating: "a", count: 32), "Ana")
        let ben = teammate(String(repeating: "b", count: 32), "Ben")
        let cleo = teammate(String(repeating: "c", count: 32), "Cleo")
        let people = [
            NearbyPersonModel(kind: .teammate(deviceID: cleo.id), name: "Cleo", macName: nil, lastSeenAt: now),
            NearbyPersonModel(kind: .stranger(serviceName: "Dev"), name: "Dev", macName: nil, lastSeenAt: now),
        ]

        let rows = SidebarTeammateRowModel.rows(teammates: [ben, cleo, ana], people: people)

        #expect(rows.map(\.teammate.name) == ["Cleo", "Ana", "Ben"])
        #expect(rows.map(\.isNearby) == [true, false, false])
        #expect(TeammatesSidebarCopy.lastSeen(nil, now: now) == "Not seen yet")
    }
}
