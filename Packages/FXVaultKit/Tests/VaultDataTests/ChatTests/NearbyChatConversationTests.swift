import Foundation
import SharingKit
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// ``ChatRepository`` and ``NearbyChatConversation`` over an `InMemoryTransportPair` (v0.2.0
/// nearby chat): two vaults with different keys (``ShareWorld``), the attachment picker list,
/// the offer behind a share authorization, the value decrypted only on request, the received
/// value forwarded without it, saving through the normal share import, and wiping on close.
@Suite("Nearby chat conversation", .timeLimit(.minutes(1)))
struct NearbyChatConversationTests {
    struct Parties {
        let world: ShareWorld
        let senderChat: ChatRepository
        let receiverChat: ChatRepository
        let sender: NearbyChatConversation
        let receiver: NearbyChatConversation
        let senderEvents: StreamReader<NearbyChatEvent>
        let receiverEvents: StreamReader<NearbyChatEvent>
        let pair: InMemoryTransportPair
    }

    private func parties() async throws -> Parties {
        let world = try await ShareWorld.make()
        let pair = InMemoryTransportPair()
        // Packages are dated by the vault clocks; the chat timers wait on manual clocks (never fire).
        let senderChat = ChatRepository(session: world.sender.session, sharing: world.senderSharing, clock: world.sender.clock)
        let receiverChat = ChatRepository(session: world.receiver.session, sharing: world.receiverSharing, clock: world.receiver.clock)
        let sender = senderChat.makeConversation(role: .initiator, transport: pair.initiator, localName: "Sender Mac", clock: ManualClock())
        let receiver = receiverChat.makeConversation(role: .responder, transport: pair.responder, localName: "Receiver Mac", clock: ManualClock())
        return Parties(
            world: world,
            senderChat: senderChat,
            receiverChat: receiverChat,
            sender: sender,
            receiver: receiver,
            senderEvents: StreamReader(sender.events),
            receiverEvents: StreamReader(receiver.events),
            pair: pair
        )
    }

    /// Both started, codes compared and confirmed.
    private func verified(_ parties: Parties) async throws {
        try await parties.receiver.start()
        try await parties.sender.start()
        let senderCode = await parties.senderEvents.first { $0.chatSAS != nil || $0.isChatTerminal }?.chatSAS
        let receiverCode = await parties.receiverEvents.first { $0.chatSAS != nil || $0.isChatTerminal }?.chatSAS
        #expect(senderCode != nil)
        #expect(senderCode?.code == receiverCode?.code)
        #expect(senderCode?.peerName == "Receiver Mac")
        try await parties.sender.confirmCode()
        try await parties.receiver.confirmCode()
        #expect(await parties.senderEvents.first { $0 == .verified || $0.isChatTerminal } == .verified)
        #expect(await parties.receiverEvents.first { $0 == .verified || $0.isChatTerminal } == .verified)
    }

    private func offer(_ name: String, kind: ConfigKind, environment: String? = nil, in parties: Parties) async throws -> ChatAttachmentOfferModel {
        let sender = parties.world.sender
        let scope: ConfigScope = if let environment {
            .environment(try #require(try sender.environment(environment)).id)
        } else {
            .repository
        }
        let item = try #require(try sender.item(name, kind: kind, scope: scope))
        return try await parties.sender.offerItem(
            item.id,
            senderName: ShareWorld.senderName,
            appVersion: ShareWorld.appVersion,
            authorization: parties.world.authorization(.nearbySend)
        )
    }

    // MARK: - Picker

    @Test func thePickerListsLiveItemsWithAValueByScope() async throws {
        let world = try await ShareWorld.make()
        let sender = ChatRepository(session: world.sender.session, sharing: world.senderSharing)
        let listed = try sender.attachableItems()
        #expect(listed.map(\.name) == ["FXV_S1", "FXV_V1", "FXV_S2", "FXV_V2"])
        #expect(listed.map(\.environmentName) == [nil, nil, "production", "production"])
        #expect(Set(listed.map(\.repositoryFullName)) == ["owner-a/api"])

        // A secret whose value is missing locally cannot be sent.
        let receiver = ChatRepository(session: world.receiver.session, sharing: world.receiverSharing)
        #expect(try receiver.attachableItems().map(\.name) == ["FXV_V1"])

        world.sender.manager.lock()
        #expect(throws: NearbyChatError.sharing(.vault(.locked))) {
            _ = try sender.attachableItems()
        }
        world.folder.remove()
    }

    // MARK: - Text and attachments

    @Test func textAndAnAttachmentReachTheOtherVaultThroughTheShareImport() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        try await verified(parties)

        let sent = try await parties.sender.sendText("  Hello\r\nteam  ")
        #expect(sent.text == "Hello\nteam")
        #expect(sent.direction == .sent)
        guard case .message(let received) = await parties.receiverEvents.first(where: { $0.isChatMessage || $0.isChatTerminal }) else {
            Issue.record("No message")
            return
        }
        #expect(received.text == "Hello\nteam")
        #expect(received.direction == .received)

        // The offer carries names only.
        let offer = try await offer("FXV_S2", kind: .secret, environment: "production", in: parties)
        #expect(offer.direction == .sent)
        guard case .attachmentOffered(let card) = await parties.receiverEvents.first(where: { $0.isOffer || $0.isChatTerminal }) else {
            Issue.record("No offer")
            return
        }
        #expect(card.itemName == "FXV_S2")
        #expect(card.kind == .secret)
        #expect(card.environmentName == "production")
        #expect(card.repositoryFullName == "owner-a/api")
        #expect(card.manifest.flattenedItems.allSatisfy { $0.item.value == nil })

        // "Save to my vault": the value arrives, forwarded without it.
        try await parties.receiver.requestAttachment(card.id)
        guard case .attachmentReceived(let id, let forwarded) = await parties.receiverEvents.first(where: { $0.isReceived || $0.isChatTerminal }) else {
            Issue.record("No payload")
            return
        }
        #expect(id == card.id)
        #expect(forwarded.flattenedItems.allSatisfy { $0.item.value == nil })
        #expect(await parties.senderEvents.first { $0 == .attachmentSent(offer.id) || $0.isChatTerminal } == .attachmentSent(offer.id))
        #expect(await parties.receiver.receivedCount == 1)

        // Planned and applied like any share; the value is re-encrypted under the receiver's key.
        let draft = try await parties.receiver.previewAttachment(id, checkGitHub: false)
        #expect(await parties.receiver.receivedCount == 0)
        #expect(draft.plan.item("FXV_S2", environment: "production")?.chip == .fillsMissingValue)
        let result = try await parties.world.receiverSharing.apply(draft, plan: draft.plan, confirmReplay: false)
        #expect(result.filled == ["production/FXV_S2"])
        let receiver = parties.world.receiver
        let production = try #require(try receiver.environment("production"))
        let saved = try #require(try receiver.item("FXV_S2", kind: .secret, scope: .environment(production.id)))
        #expect(try receiver.value(saved.id) == "a2")
        await #expect(throws: NearbyChatError.attachmentUnavailable) {
            _ = try await parties.receiver.previewAttachment(id, checkGitHub: false)
        }

        await parties.sender.close()
        #expect(await parties.receiverEvents.first { $0.isChatTerminal } == .peerClosed)
    }

    @Test func anOfferNeedsAFreshShareAuthorization() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        try await verified(parties)
        let item = try #require(try parties.world.sender.item("FXV_S1", kind: .secret))

        let used = parties.world.authorization(.nearbySend)
        _ = try await parties.sender.offerItem(item.id, senderName: "S", appVersion: "1", authorization: used)
        await #expect(throws: NearbyChatError.sharing(.authorizationInvalid)) {
            _ = try await parties.sender.offerItem(item.id, senderName: "S", appVersion: "1", authorization: used)
        }
        await #expect(throws: NearbyChatError.sharing(.authorizationInvalid)) {
            _ = try await parties.sender.offerItem(
                item.id,
                senderName: "S",
                appVersion: "1",
                authorization: parties.world.authorization(.fileExport)
            )
        }
        // Authorized in another vault's session.
        let foreign = ShareAuthorizationModel(purpose: .nearbySend, session: parties.world.receiver.session)
        await #expect(throws: NearbyChatError.sharing(.authorizationInvalid)) {
            _ = try await parties.sender.offerItem(item.id, senderName: "S", appVersion: "1", authorization: foreign)
        }
        await parties.sender.close()
    }

    @Test func aSecretWithoutAValueCannotBeOffered() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        try await verified(parties)
        let receiverVault = parties.world.receiver
        let production = try #require(try receiverVault.environment("production"))
        let missing = try #require(try receiverVault.item("FXV_S2", kind: .secret, scope: .environment(production.id)))
        await #expect(throws: NearbyChatError.valueMissing) {
            _ = try await parties.receiver.offerItem(
                missing.id,
                senderName: "R",
                appVersion: "1",
                authorization: ShareAuthorizationModel(purpose: .nearbySend, session: receiverVault.session)
            )
        }
        await parties.receiver.close()
    }

    @Test func anItemRenamedAfterTheOfferIsWithdrawnInsteadOfSent() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        try await verified(parties)
        let offer = try await offer("FXV_S1", kind: .secret, in: parties)
        guard case .attachmentOffered(let card) = await parties.receiverEvents.first(where: { $0.isOffer || $0.isChatTerminal }) else {
            Issue.record("No offer")
            return
        }
        let item = try #require(try parties.world.sender.item("FXV_S1", kind: .secret))
        _ = try parties.world.sender.config.renameItem(item.id, to: "FXV_RENAMED")

        try await parties.receiver.requestAttachment(card.id)
        let outcome = await parties.receiverEvents.first { $0.isReceived || $0 == .attachmentDeclined(card.id) || $0.isChatTerminal }
        #expect(outcome == .attachmentDeclined(offer.id))
        #expect(await parties.receiver.receivedCount == 0)
        await parties.sender.close()
    }

    @Test func aValueChangedAfterTheOfferIsWithdrawnInsteadOfSent() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        try await verified(parties)
        let offer = try await offer("FXV_S1", kind: .secret, in: parties)
        guard case .attachmentOffered(let card) = await parties.receiverEvents.first(where: { $0.isOffer || $0.isChatTerminal }) else {
            Issue.record("No offer")
            return
        }
        // The user rotates the value after authorizing the offer: the new value was never
        // authorized for this peer.
        let item = try #require(try parties.world.sender.item("FXV_S1", kind: .secret))
        _ = try parties.world.sender.config.editValue(item.id, value: SecretBytes(utf8: "rotated"))

        try await parties.receiver.requestAttachment(card.id)
        let outcome = await parties.receiverEvents.first { $0.isReceived || $0 == .attachmentDeclined(card.id) || $0.isChatTerminal }
        #expect(outcome == .attachmentDeclined(offer.id))
        #expect(await parties.receiver.receivedCount == 0)
        await parties.sender.close()
    }

    @Test func closingWipesAReceivedValueThatWasNotSaved() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        try await verified(parties)
        _ = try await offer("FXV_V2", kind: .variable, environment: "production", in: parties)
        guard case .attachmentOffered(let card) = await parties.receiverEvents.first(where: { $0.isOffer || $0.isChatTerminal }) else {
            Issue.record("No offer")
            return
        }
        try await parties.receiver.requestAttachment(card.id)
        _ = await parties.receiverEvents.first { $0.isReceived || $0.isChatTerminal }
        #expect(await parties.receiver.receivedCount == 1)

        await parties.receiver.close()
        #expect(await parties.receiver.receivedCount == 0)
        await #expect(throws: NearbyChatError.attachmentUnavailable) {
            _ = try await parties.receiver.previewAttachment(card.id, checkGitHub: false)
        }
        await #expect(throws: NearbyChatError.chat(.sessionFinished)) {
            _ = try await parties.receiver.sendText("still there?")
        }
        #expect(await parties.senderEvents.first { $0.isChatTerminal } == .peerClosed)
        #expect(try parties.world.receiver.item("FXV_V2", kind: .variable, scope: .environment(
            try #require(try parties.world.receiver.environment("production")).id
        )) == nil)
    }

    @Test func aDisconnectWipesAReceivedValue() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        try await verified(parties)
        _ = try await offer("FXV_V1", kind: .variable, in: parties)
        guard case .attachmentOffered(let card) = await parties.receiverEvents.first(where: { $0.isOffer || $0.isChatTerminal }) else {
            Issue.record("No offer")
            return
        }
        try await parties.receiver.requestAttachment(card.id)
        _ = await parties.receiverEvents.first { $0.isReceived || $0.isChatTerminal }
        #expect(await parties.receiver.receivedCount == 1)

        parties.pair.initiator.close()
        let ending = await parties.receiverEvents.first { $0.isChatTerminal }
        #expect(ending == .aborted(NearbyAbortModel(reason: .disconnected, happenedAfterReveal: true)))
        #expect(await parties.receiver.receivedCount == 0)
    }
}

extension NearbyChatEvent {
    var chatSAS: NearbySASModel? {
        if case .sasReady(let model) = self { return model }
        return nil
    }

    var isChatMessage: Bool {
        if case .message = self { return true }
        return false
    }

    var isOffer: Bool {
        if case .attachmentOffered = self { return true }
        return false
    }

    var isReceived: Bool {
        if case .attachmentReceived = self { return true }
        return false
    }

    var isChatTerminal: Bool {
        switch self {
        case .peerClosed, .aborted: true
        default: false
        }
    }
}

// MARK: - Whole repository (v0.4.0, chat v2)

extension NearbyChatConversationTests {
    private func offerRepository(in parties: Parties) async throws -> ChatAttachmentOfferModel {
        try await parties.sender.offerRepository(
            try parties.world.sender.repository().id,
            senderName: ShareWorld.senderName,
            appVersion: ShareWorld.appVersion,
            authorization: parties.world.authorization(.nearbySend)
        )
    }

    /// A second repository in the receiver's vault, never imported from the sender.
    private func otherRepository(in world: ShareWorld) throws -> RepoModel {
        let repository = RepoModel(
            accountLogin: SyncFixture.login,
            githubID: "R_other_project",
            ownerLogin: "owner-b",
            ownerType: .organization,
            name: "project",
            visibility: .private,
            isArchived: false,
            hasAdmin: true,
            hasPush: true,
            origin: .imported,
            importedAt: ShareWorld.secretUpdatedAt
        )
        try RepoStore(database: world.receiver.database).insert(repository)
        return repository
    }

    // MARK: - Folders (v0.7.0)

    private func offerFolder(in parties: Parties) async throws -> (FolderID, ChatAttachmentOfferModel) {
        let folder = try FolderSharingTests.mobileFolder(in: parties.world)
        let offer = try await parties.sender.offerFolder(
            folder,
            senderName: ShareWorld.senderName,
            appVersion: ShareWorld.appVersion,
            authorization: parties.world.authorization(.nearbySend)
        )
        return (folder, offer)
    }

    @Test func aFolderIsSavedAsAFolderOrImportedIntoAScope() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        try await verified(parties)
        #expect(await parties.sender.acceptsFolderAttachments)

        let (folder, offer) = try await offerFolder(in: parties)
        #expect(offer.folderName == "Mobile App")
        guard case .attachmentOffered(let card) = await parties.receiverEvents.first(where: { $0.isOffer || $0.isChatTerminal }),
              case .folder(let summary) = card.content
        else {
            Issue.record("No folder offer")
            return
        }
        #expect(summary.name == "Mobile App" && summary.secretCount == 1 && summary.variableCount == 1)
        try await parties.receiver.requestAttachment(card.id)
        guard case .attachmentReceived(let id, let forwarded) = await parties.receiverEvents.first(where: { $0.isReceived || $0.isChatTerminal }) else {
            Issue.record("No payload")
            return
        }
        #expect(forwarded.isFolder)
        #expect(forwarded.flattenedItems.allSatisfy { $0.item.value == nil })

        let saved = try await parties.receiver.saveFolderAttachment(id, as: .newFolder(name: "Mobile App"), conflicts: .keep)
        #expect(saved.items == ItemCopyResultModel(added: 2))
        #expect(await parties.receiver.receivedCount == 0)
        let receiverFolders = FolderRepository(session: parties.world.receiver.session)
        #expect(try receiverFolders.items(folderID: saved.folderID).map(\.name) == ["API_KEY", "API_URL"])
        await #expect(throws: NearbyChatError.attachmentUnavailable) {
            _ = try await parties.receiver.saveFolderAttachment(id, as: .existing(saved.folderID), conflicts: .keep)
        }

        // A second copy goes into the receiver's repository instead.
        let second = try await parties.sender.offerFolder(
            folder,
            senderName: ShareWorld.senderName,
            appVersion: ShareWorld.appVersion,
            authorization: parties.world.authorization(.nearbySend)
        )
        _ = await parties.receiverEvents.first { $0.isOffer || $0.isChatTerminal }
        try await parties.receiver.requestAttachment(second.id)
        guard case .attachmentReceived(let secondID, _) = await parties.receiverEvents.first(where: { $0.isReceived || $0.isChatTerminal }) else {
            Issue.record("No second payload")
            return
        }
        let repository = try parties.world.receiver.repository()
        let draft = try await parties.receiver.previewFolderAttachment(secondID, into: repository.id, scope: .repository, checkGitHub: false)
        let result = try await parties.world.receiverSharing.apply(draft, plan: draft.plan, confirmReplay: true)
        #expect(Set(result.added + result.overwritten + result.filled).isSuperset(of: ["API_KEY", "API_URL"]))
        await parties.sender.close()
    }

    @Test func aFolderOfferIsWithdrawnWhenAValueChangedSince() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        try await verified(parties)
        let (folder, offer) = try await offerFolder(in: parties)
        _ = await parties.receiverEvents.first { $0.isOffer || $0.isChatTerminal }

        let folders = FolderRepository(session: parties.world.sender.session)
        let item = try #require(try folders.items(folderID: folder).first)
        try folders.editItem(item.id, name: item.name, kind: item.kind, value: SecretBytes(utf8: "edited-after-the-offer"))
        try await parties.receiver.requestAttachment(offer.id)

        #expect(await parties.receiverEvents.first { $0 == .attachmentDeclined(offer.id) || $0.isChatTerminal }
            == .attachmentDeclined(offer.id))
        #expect(await parties.receiver.receivedCount == 0)
        await parties.sender.close()
    }

    @Test func aWholeRepositoryIsImportedIntoAnotherRepositoryOfTheReceiver() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        try await verified(parties)
        #expect(await parties.sender.acceptsConfigurationAttachments)

        let offer = try await offerRepository(in: parties)
        #expect(offer.isConfiguration)
        guard case .attachmentOffered(let card) = await parties.receiverEvents.first(where: { $0.isOffer || $0.isChatTerminal }),
              case .configuration(let summary) = card.content
        else {
            Issue.record("No configuration offer")
            return
        }
        #expect(card.repositoryFullName == "owner-a/api")
        #expect(summary.environmentNames == ["production"])
        #expect(summary.secretCount == 2)
        #expect(summary.variableCount == 2)
        #expect(card.manifest.flattenedItems.allSatisfy { $0.item.value == nil })

        try await parties.receiver.requestAttachment(card.id)
        guard case .attachmentReceived(let id, let forwarded) = await parties.receiverEvents.first(where: { $0.isReceived || $0.isChatTerminal }) else {
            Issue.record("No payload")
            return
        }
        #expect(forwarded.flattenedItems.allSatisfy { $0.item.value == nil }, "forwarded without values")

        let target = try otherRepository(in: parties.world)
        let draft = try await parties.receiver.previewAttachment(id, into: target.id, checkGitHub: false)
        #expect(draft.package.repository.fullName == "owner-b/project")
        #expect(draft.plan.blockReason == nil)
        let result = try await parties.world.receiverSharing.apply(draft, plan: draft.plan, confirmReplay: false)
        #expect(Set(result.added) == ["FXV_S1", "FXV_V1", "production/FXV_S2", "production/FXV_V2"])

        let config = parties.world.receiver.config
        let scopes = try config.scopes(repositoryID: target.id)
        let production = try #require(scopes.first { $0.environment?.name == "production" })
        let records = try ConfigStore(database: parties.world.receiver.database).fetchItemRecords(repositoryID: target.id)
        let s2 = try #require(records.first { $0.name == "FXV_S2" && $0.scope == production.scope })
        #expect(try parties.world.receiver.value(s2.id) == "a2")
        #expect(try parties.world.receiver.item("FXV_V1", kind: .variable).map { try parties.world.receiver.value($0.id) } == "different",
                "the sender's own repository in the receiver's vault is untouched")
        await parties.sender.close()
    }

    @Test func aRepositoryOfferIsWithdrawnWhenAValueChangedSince() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        try await verified(parties)
        let offer = try await offerRepository(in: parties)
        _ = await parties.receiverEvents.first { $0.isOffer || $0.isChatTerminal }

        let s1 = try #require(try parties.world.sender.item("FXV_S1", kind: .secret))
        try parties.world.sender.config.editValue(s1.id, value: SecretBytes(utf8: "edited-after-the-offer"))
        try await parties.receiver.requestAttachment(offer.id)

        #expect(await parties.receiverEvents.first { $0 == .attachmentDeclined(offer.id) || $0.isChatTerminal }
            == .attachmentDeclined(offer.id))
        #expect(await parties.receiver.receivedCount == 0)
        await parties.sender.close()
    }

    @Test func aReceivedRepositoryCanBeSavedAsAnEncryptedFileAndStillImported() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        try await verified(parties)
        let offer = try await offerRepository(in: parties)
        _ = await parties.receiverEvents.first { $0.isOffer || $0.isChatTerminal }
        try await parties.receiver.requestAttachment(offer.id)
        guard case .attachmentReceived(let id, _) = await parties.receiverEvents.first(where: { $0.isReceived || $0.isChatTerminal }) else {
            Issue.record("No payload")
            return
        }

        let destination = parties.world.folder.url.appendingPathComponent("received.fxvault")
        let receiverAuthorization = ShareAuthorizationModel(purpose: .fileExport, session: parties.world.receiver.session)
        let saved = try await parties.receiver.saveAttachment(id, to: destination, authorization: receiverAuthorization)
        defer { saved.passphrase.wipe() }
        #expect(saved.fileURL == destination)
        await #expect(throws: NearbyChatError.sharing(.authorizationInvalid)) {
            _ = try await parties.receiver.saveAttachment(id, to: destination, authorization: receiverAuthorization)
        }

        let passphrase = try #require(saved.passphrase.utf8String())
        let reopened = try await parties.world.receiverSharing.openFile(
            parties.world.receiverSharing.readFile(at: destination),
            passphrase: passphrase,
            checkGitHub: false
        )
        #expect(reopened.package.flattenedItems.count == 4)
        reopened.discard()
        #expect(await parties.receiver.receivedCount == 1, "saving keeps the package for an import")
        _ = try await parties.receiver.previewAttachment(id, checkGitHub: false)
        await parties.sender.close()
    }
}
