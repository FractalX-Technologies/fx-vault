import Foundation
import SharingKit
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Remote pairing in the vault (v0.9.0, P4): invitation, reply, the code both Macs show, the
/// confirmations that are the only writes, and the two routes for the inviter's announce key
/// (a nearby card update and a teammates file).
@Suite("Remote pairing repository")
struct RemotePairingRepositoryTests {
    private static let ana = SpaceLocalIdentityModel(login: "user-a", displayName: "Ana", macName: "Ana's Mac")
    private static let ben = SpaceLocalIdentityModel(login: "user-b", displayName: "Ben", macName: "Ben's Mac")

    /// One Mac: its vault and its teammate repository.
    private struct Mac {
        let harness: ConfigHarness
        let team: TeamRepository
        let identity: SpaceLocalIdentityModel

        static func make(_ identity: SpaceLocalIdentityModel) async throws -> Mac {
            let harness = try await ConfigHarness.make()
            return Mac(harness: harness, team: TeamRepository(session: harness.session, clock: harness.clock), identity: identity)
        }

        /// This Mac's real card (with its announce key), as a nearby card update sends it.
        func card() throws -> TeamCardModel {
            try team.deviceKeys().card(login: identity.login, displayName: identity.displayName, macName: identity.macName)
        }

        func teammate(_ other: Mac) throws -> TeammateModel? {
            let id = try other.team.deviceKeys().deviceID.hex
            return try team.teammates().first { $0.id == id }
        }

        func storedCard(of other: Mac) throws -> TeamCardModel? {
            let id = try other.team.deviceKeys().deviceID
            return try team.teammateCards().first { $0.deviceID == id }
        }
    }

    /// Runs steps 1–3 without confirming.
    private static func exchange(
        inviter: Mac,
        replier: Mac
    ) throws -> (invitation: RemoteInvitationReadModel, reply: RemotePairingReplyFileModel, read: RemoteReplyReadModel) {
        let file = try inviter.team.makeInvitation(as: inviter.identity)
        let invitation = try replier.team.readInvitation(file)
        let reply = try replier.team.makeReply(to: invitation.invitation, as: replier.identity)
        let read = try inviter.team.readReply(reply.file)
        return (invitation, reply, read)
    }

    @Test func bothMacsEndAsTeammatesAfterComparingTheSameCode() async throws {
        let a = try await Mac.make(Self.ana)
        let b = try await Mac.make(Self.ben)

        let (invitation, reply, read) = try Self.exchange(inviter: a, replier: b)
        #expect(invitation.inviter.name == "Ana")
        #expect(invitation.existingTeammate == nil)
        #expect(read.existingTeammate == nil)
        #expect(read.code == reply.code)
        #expect(read.code.words.count == RemotePairingProtocol.codeWordCount)
        #expect(read.teammate.name == "Ben")

        #expect(try b.team.confirmInviter(reply.inviter) == .added)
        #expect(try a.team.confirmReplier(read.teammate) == .added)

        let anaOnBen = try #require(try b.teammate(a))
        #expect(anaOnBen.pairedVia == .remote)
        #expect(!anaOnBen.hasAnnounceKey, "the inviter's announce key never crosses the chat")
        #expect(!anaOnBen.needsCardUpdate)
        let placeholder = try #require(try b.storedCard(of: a))
        #expect(placeholder.signingPublicKey == (try a.card()).signingPublicKey)
        #expect(placeholder.announceKey != (try a.card()).announceKey)

        let benOnAna = try #require(try a.teammate(b))
        #expect(benOnAna.pairedVia == .remote)
        #expect(benOnAna.hasAnnounceKey)
        #expect(benOnAna.needsCardUpdate, "Ben still needs Ana's card with her announce key")
        #expect(try a.storedCard(of: b) == (try b.card()))
    }

    @Test func readingAndMakingFilesStoreNoTeammate() async throws {
        let a = try await Mac.make(Self.ana)
        let b = try await Mac.make(Self.ben)
        _ = try a.team.deviceKeys()
        _ = try b.team.deviceKeys()
        let identities = try [a, b].map { mac in
            try mac.harness.database.read { tx in try TeamStore(database: mac.harness.database).fetchIdentity(in: tx) }
        }

        _ = try Self.exchange(inviter: a, replier: b)
        _ = try Self.exchange(inviter: b, replier: a)

        #expect(try a.team.teammates().isEmpty)
        #expect(try b.team.teammates().isEmpty)
        let after = try [a, b].map { mac in
            try mac.harness.database.read { tx in try TeamStore(database: mac.harness.database).fetchIdentity(in: tx) }
        }
        #expect(after == identities, "this device's keys are not renewed")
    }

    @Test func aNearbyCardUpdateDeliversTheInvitersAnnounceKey() async throws {
        let a = try await Mac.make(Self.ana)
        let b = try await Mac.make(Self.ben)
        let (_, reply, read) = try Self.exchange(inviter: a, replier: b)
        try b.team.confirmInviter(reply.inviter)
        try a.team.confirmReplier(read.teammate)

        // Ana recognizes Ben nearby (she has his announce key) and sends her card; Ben answers
        // with the card he stored for her, whose announce key is only a placeholder.
        let anaCard = try a.card()
        let benOnAna = try #require(try a.storedCard(of: b))
        let pair = InMemoryTransportPair()
        let update = TeamSession.connect(to: benOnAna, keys: try a.team.deviceKeys(), requests: [.updateCard(anaCard)], transport: pair.initiator)
        try await update.start()
        let routed = try #require(await TeamRouter.route(pair.responder))
        let answer = TeamSession.answer(keys: try b.team.deviceKeys(), teammates: try b.team.teammateCards(), transport: routed.transport)
        try await answer.start()

        var received: TeamCardModel?
        for await event in answer.events {
            if case .cardUpdated(let card) = event {
                received = card
            }
        }
        var delivered = false
        for await event in update.events where event == .cardUpdateDelivered {
            delivered = true
        }
        let card = try #require(received)
        try b.team.applyCardUpdate(card)
        #expect(delivered)
        try a.team.cardUpdateDelivered(to: try b.team.deviceKeys().deviceID.hex)

        let anaOnBen = try #require(try b.teammate(a))
        #expect(anaOnBen.hasAnnounceKey)
        #expect(anaOnBen.pairedVia == .remote)
        #expect(try b.storedCard(of: a) == anaCard)
        #expect(try a.teammate(b)?.needsCardUpdate == false)
    }

    @Test func aTeammatesFileDeliversTheInvitersAnnounceKey() async throws {
        let a = try await Mac.make(Self.ana)
        let b = try await Mac.make(Self.ben)
        let (_, reply, read) = try Self.exchange(inviter: a, replier: b)
        try b.team.confirmInviter(reply.inviter)
        try a.team.confirmReplier(read.teammate)

        let codec = FxVaultFileV2Codec(deriver: Argon2idSharingDeriver())
        let benOnAna = try #require(try a.storedCard(of: b))
        let file = try codec.sealForTeammates(
            payload: SecretBytes(Data("{}".utf8)),
            sender: try a.team.deviceKeys(),
            recipients: [ShareTeammateKeyModel(card: benOnAna)]
        )
        let opened = try codec.openAsTeammate(
            file,
            device: try b.team.deviceKeys(),
            teammates: try b.team.teammateCards().map(ShareTeammateKeyModel.init(card:))
        )
        defer { opened.payload.wipe() }
        #expect(opened.sender == (try a.team.deviceKeys()).deviceID)

        #expect(try b.team.fillAnnounceKeyIfMissing(opened.senderAnnounceKey, teammate: opened.sender.hex))
        #expect(try b.storedCard(of: a) == (try a.card()))
        #expect(try b.teammate(a)?.hasAnnounceKey == true)
        #expect(try !b.team.fillAnnounceKeyIfMissing(opened.senderAnnounceKey, teammate: opened.sender.hex), "a known key is kept")
    }

    @Test func pairingAnExistingTeammateAgainUpdatesItWithoutADuplicate() async throws {
        let a = try await Mac.make(Self.ana)
        let b = try await Mac.make(Self.ben)
        try a.team.addTeammate(try b.card())
        try b.team.addTeammate(try a.card())

        let renamed = SpaceLocalIdentityModel(login: "user-a", displayName: "Ana R.", macName: "Ana's Mac")
        let file = try a.team.makeInvitation(as: renamed)
        let invitation = try b.team.readInvitation(file)
        #expect(invitation.existingTeammate?.name == "Ana")
        let reply = try b.team.makeReply(to: invitation.invitation, as: b.identity)
        let read = try a.team.readReply(reply.file)
        #expect(read.existingTeammate?.name == "Ben")

        #expect(try b.team.confirmInviter(reply.inviter) == .updated)
        #expect(try a.team.confirmReplier(read.teammate) == .updated)

        #expect(try b.team.teammates().count == 1)
        #expect(try a.team.teammates().count == 1)
        let anaOnBen = try #require(try b.teammate(a))
        #expect(anaOnBen.name == "Ana R.")
        #expect(anaOnBen.hasAnnounceKey, "the announce key from nearby pairing is kept")
        #expect(try b.storedCard(of: a)?.announceKey == (try a.card()).announceKey)
    }

    @Test func aMacRefusesItsOwnInvitation() async throws {
        let a = try await Mac.make(Self.ana)
        let file = try a.team.makeInvitation(as: a.identity)
        #expect(throws: TeamRepositoryError.keys(.pairingOwnCard)) { try a.team.readInvitation(file) }
    }

    @Test func anInvitationOlderThanSevenDaysIsRefused() async throws {
        let a = try await Mac.make(Self.ana)
        let b = try await Mac.make(Self.ben)
        let file = try a.team.makeInvitation(as: a.identity)
        b.harness.clock.advance(by: Timeouts.pairingInvitationMaxAge + .seconds(1))
        #expect(throws: TeamRepositoryError.keys(.pairingExpired)) { try b.team.readInvitation(file) }
        #expect(try b.team.teammates().isEmpty)
    }

    @Test func aReplyToAnotherMacsInvitationIsRefused() async throws {
        let a = try await Mac.make(Self.ana)
        let b = try await Mac.make(Self.ben)
        let c = try await Mac.make(SpaceLocalIdentityModel(login: "user-c", displayName: "Cy", macName: "Cy's Mac"))
        let invitation = try b.team.readInvitation(try c.team.makeInvitation(as: c.identity))
        let reply = try b.team.makeReply(to: invitation.invitation, as: b.identity)

        #expect(throws: TeamRepositoryError.keys(.invalidPairingCard)) { try a.team.readReply(reply.file) }
        #expect(try a.team.teammates().isEmpty)
    }

    @Test func everyStepNeedsAnUnlockedVault() async throws {
        let a = try await Mac.make(Self.ana)
        let b = try await Mac.make(Self.ben)
        let (invitation, reply, read) = try Self.exchange(inviter: a, replier: b)
        let file = try a.team.makeInvitation(as: a.identity)
        a.harness.manager.lock()
        b.harness.manager.lock()

        #expect(throws: TeamRepositoryError.vault(.locked)) { try a.team.makeInvitation(as: a.identity) }
        #expect(throws: TeamRepositoryError.vault(.locked)) { try b.team.readInvitation(file) }
        #expect(throws: TeamRepositoryError.vault(.locked)) { try b.team.makeReply(to: invitation.invitation, as: b.identity) }
        #expect(throws: TeamRepositoryError.vault(.locked)) { try a.team.readReply(reply.file) }
        #expect(throws: TeamRepositoryError.vault(.locked)) { try b.team.confirmInviter(reply.inviter) }
        #expect(throws: TeamRepositoryError.vault(.locked)) { try a.team.confirmReplier(read.teammate) }
    }

    @Test func openedCardFilesAreRoutedByKind() async throws {
        let a = try await Mac.make(Self.ana)
        let b = try await Mac.make(Self.ben)
        let (_, reply, _) = try Self.exchange(inviter: a, replier: b)

        #expect(try TeamRepository.pairingFileKind(of: try a.team.makeInvitation(as: a.identity)) == .invitation)
        #expect(try TeamRepository.pairingFileKind(of: reply.file) == .reply)
        #expect(throws: TeamRepositoryError.keys(.invalidPairingCard)) {
            try TeamRepository.pairingFileKind(of: Data("not a card".utf8))
        }
        #expect(throws: TeamRepositoryError.keys(.invalidPairingCard)) { try b.team.readInvitation(reply.file) }
        #expect(throws: TeamRepositoryError.keys(.invalidPairingCard)) { try a.team.readReply(try a.team.makeInvitation(as: a.identity)) }
    }
}
