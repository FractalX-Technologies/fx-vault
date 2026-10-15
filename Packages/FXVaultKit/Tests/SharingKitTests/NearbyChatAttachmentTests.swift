import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// Attachments in a chat: ATTACHMENT_OFFER → REQUEST → PAYLOAD, DECLINE and their violations.
@Suite("Nearby chat attachments")
struct NearbyChatAttachmentTests {
    /// Runs to chatting and makes the initiator offer `package`. Returns the offer as sent.
    static func offered(
        _ package: SharePackageModel,
        harness: inout ChatHarness
    ) throws -> ChatAttachmentOfferModel {
        try harness.runToChatting()
        let (step, offer) = try harness.initiator.offerAttachment(package)
        harness.recordInitiator(step)
        harness.pump()
        return try #require(offer)
    }

    @Test func offerRequestPayloadDeliversTheValue() throws {
        var harness = try ChatHarness.kat()
        let package = ChatAttachmentFactory.secret("API_KEY", value: "s3cr3t-value")
        let sent = try Self.offered(package, harness: &harness)
        #expect(sent.direction == .sent)
        #expect(sent.kind == .secret)
        #expect(sent.itemName == "API_KEY")
        #expect(sent.manifest.flattenedItems.allSatisfy { $0.item.value == nil })

        // The OFFER frame carries names only: the value never left before a request.
        let offerFrame = try #require(harness.initiatorFrames.last)
        #expect(offerFrame.encryptedType == NearbyChatMessageType.attachmentOffer.rawValue)
        let card = try #require(harness.responderEvents.compactMap(\.offerModel).first)
        #expect(card.id == sent.id)
        #expect(card.direction == .received)
        #expect(card.kind == .secret)
        #expect(card.itemName == "API_KEY")
        #expect(card.repositoryFullName == "\(PackageFactory.owner)/\(PackageFactory.repository)")
        #expect(card.environmentName == nil)
        #expect(card.level == .repository)
        #expect(card.manifest.flattenedItems.allSatisfy { $0.item.value == nil })
        #expect(card.manifest.flattenedItems.first?.item.valueState == .present)

        harness.recordResponder(try harness.responder.requestAttachment(card.id))
        harness.pump()
        #expect(harness.initiatorRequests == [card.id])
        // A second request for the same offer is refused locally.
        #expect(throws: ChatError.unknownAttachment) { _ = try harness.responder.requestAttachment(card.id) }

        let value = SecretBytes(utf8: "s3cr3t-value")
        harness.recordInitiator(try harness.initiator.sendAttachmentPayload(card.id, value: value))
        harness.pump()
        #expect(harness.initiatorEvents.last == .attachmentSent(card.id))
        let (receivedID, payload) = try #require(harness.responderEvents.compactMap(\.receivedAttachment).first)
        #expect(receivedID == card.id)
        #expect(payload.manifest() == card.manifest)
        #expect(payload.flattenedItems.first?.item.value?.utf8String() == "s3cr3t-value")
        payload.wipeValues()
        #expect(payload.flattenedItems.first?.item.value?.isWiped == true)
        // Both sides forget the offer once it is delivered.
        #expect(throws: ChatError.unknownAttachment) { _ = try harness.initiator.sendAttachmentPayload(card.id, value: value) }
        #expect(throws: ChatError.unknownAttachment) { _ = try harness.responder.declineAttachment(card.id) }
        #expect(harness.initiatorAbort == nil)
        #expect(harness.responderAbort == nil)
    }

    @Test func environmentVariableAndLargeValuesSpanFrames() throws {
        var harness = try ChatHarness.kat()
        let sent = try Self.offered(ChatAttachmentFactory.environmentVariable(), harness: &harness)
        let card = try #require(harness.responderEvents.compactMap(\.offerModel).first)
        #expect(card.kind == .variable)
        #expect(card.environmentName == "staging")
        #expect(card.level == .environment)
        #expect(sent.environmentName == "staging")

        // The largest value, JSON-escaped to about twice its size, needs several frames.
        let value = String(repeating: "\"", count: Limits.maxValueBytes)
        var second = try ChatHarness.kat()
        let big = try Self.offered(ChatAttachmentFactory.secret(value: value), harness: &second)
        second.recordResponder(try second.responder.requestAttachment(big.id))
        second.pump()
        let step = try second.initiator.sendAttachmentPayload(big.id, value: SecretBytes(utf8: value))
        #expect(step.frames.count > 1)
        second.recordInitiator(step)
        second.pump()
        let (_, payload) = try #require(second.responderEvents.compactMap(\.receivedAttachment).first)
        #expect(payload.flattenedItems.first?.item.value?.utf8String() == value)
        payload.wipeValues()
    }

    @Test func offerMustBeOneItemWithAValue() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        let two = PackageFactory.package(
            scope: .repository,
            secrets: [PackageFactory.item("ONE"), PackageFactory.item("TWO")]
        )
        // A chat v1 (the KAT pair, as with a 0.2.x or 0.3.x peer) carries no configuration (v0.4.0).
        #expect(throws: ChatError.peerNeedsUpdate) { _ = try harness.initiator.offerAttachment(two) }
        #expect(throws: ChatError.peerNeedsUpdate) {
            _ = try harness.initiator.offerAttachment(PackageFactory.sample())
        }
        let missing = PackageFactory.package(scope: .secret, secrets: [PackageFactory.item("NO_VALUE", value: nil)])
        #expect(throws: ChatError.invalidAttachment) { _ = try harness.initiator.offerAttachment(missing) }
        let badName = PackageFactory.package(scope: .secret, secrets: [PackageFactory.item("lower case")])
        #expect(throws: ChatError.invalidAttachment) { _ = try harness.initiator.offerAttachment(badName) }
        #expect(harness.initiatorAbort == nil)
    }

    @Test func offerBeforeVerificationIsNotAllowed() throws {
        var harness = try ChatHarness.kat()
        try harness.runHandshake()
        #expect(throws: ChatError.actionNotAllowed) {
            _ = try harness.initiator.offerAttachment(ChatAttachmentFactory.secret())
        }
    }

    @Test func tooManyOpenOffers() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        for _ in 0..<Limits.chatMaxOpenAttachments {
            let (step, _) = try harness.initiator.offerAttachment(ChatAttachmentFactory.secret())
            harness.recordInitiator(step)
        }
        harness.pump()
        #expect(throws: ChatError.tooManyAttachments) {
            _ = try harness.initiator.offerAttachment(ChatAttachmentFactory.secret())
        }
        #expect(harness.responderEvents.compactMap(\.offerModel).count == Limits.chatMaxOpenAttachments)
    }

    @Test func receiverRefusesTooManyOffers() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        let forger = try ChatKATForger()
        let json = try SharePackageCoder.encode(ChatAttachmentFactory.secret().manifest())
        let manifestBytes = json.withUnsafeBytes { Data($0) }
        for sequence in 1...UInt64(Limits.chatMaxOpenAttachments + 1) {
            let body = Data(ChatAttachmentID().bytes) + manifestBytes
            harness.inject(toResponder: try forger.fromInitiator(.attachmentOffer, sequence: sequence, body: body))
        }
        #expect(harness.responderEvents.compactMap(\.offerModel).count == Limits.chatMaxOpenAttachments)
        #expect(harness.responderAbort?.reason == .unexpectedMessage)
    }

    @Test func declineReachesTheSender() throws {
        var harness = try ChatHarness.kat()
        let sent = try Self.offered(ChatAttachmentFactory.secret(), harness: &harness)
        harness.recordResponder(try harness.responder.declineAttachment(sent.id))
        harness.pump()
        #expect(harness.initiatorEvents.last == .attachmentDeclined(sent.id))
        #expect(throws: ChatError.unknownAttachment) { _ = try harness.responder.requestAttachment(sent.id) }
        // A request for the declined offer (forged) is an unknown id for the sender.
        let forged = try ChatKATForger().fromResponder(
            .attachmentRequest,
            sequence: harness.nextResponderSequence,
            body: Data(sent.id.bytes)
        )
        harness.inject(toInitiator: forged)
        #expect(harness.initiatorAbort?.reason == .unknownItemIDs)
    }

    @Test func declineAfterRequestIsNotAllowed() throws {
        var harness = try ChatHarness.kat()
        let sent = try Self.offered(ChatAttachmentFactory.secret(), harness: &harness)
        harness.recordResponder(try harness.responder.requestAttachment(sent.id))
        harness.pump()
        #expect(throws: ChatError.unknownAttachment) { _ = try harness.responder.declineAttachment(sent.id) }
        // A forged decline for a requested offer violates the protocol.
        let forged = try ChatKATForger().fromResponder(
            .attachmentDecline,
            sequence: harness.nextResponderSequence,
            body: Data(sent.id.bytes)
        )
        harness.inject(toInitiator: forged)
        #expect(harness.initiatorAbort?.reason == .unexpectedMessage)
    }

    @Test func senderWithdrawsWhenTheValueIsUnavailable() throws {
        var harness = try ChatHarness.kat()
        let sent = try Self.offered(ChatAttachmentFactory.secret(), harness: &harness)
        harness.recordResponder(try harness.responder.requestAttachment(sent.id))
        harness.pump()
        harness.recordInitiator(harness.initiator.withdrawAttachment(sent.id))
        harness.pump()
        #expect(harness.responderEvents.last == .attachmentDeclined(sent.id))
        #expect(harness.responderEvents.compactMap(\.receivedAttachment).isEmpty)
        #expect(harness.initiator.withdrawAttachment(sent.id) == .none)
        #expect(harness.responderAbort == nil)
    }

    @Test func requestForAnUnknownOfferAborts() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        let forged = try ChatKATForger().fromResponder(.attachmentRequest, sequence: 1, body: Data(ChatAttachmentID().bytes))
        harness.inject(toInitiator: forged)
        #expect(harness.initiatorAbort?.reason == .unknownItemIDs)
        #expect(harness.initiatorRequests.isEmpty)
    }

    @Test func payloadThatDiffersFromTheOfferAborts() throws {
        var harness = try ChatHarness.kat()
        let sent = try Self.offered(ChatAttachmentFactory.secret("API_KEY"), harness: &harness)
        harness.recordResponder(try harness.responder.requestAttachment(sent.id))
        harness.pump()
        // The sender swaps the item for another one.
        var swapped = ChatAttachmentFactory.secret("OTHER_KEY", value: "x")
        swapped.packageID = sent.manifest.packageID
        let json = try SharePackageCoder.encode(swapped)
        var body = Data(sent.id.bytes)
        body.appendBigEndian(UInt32(json.count))
        json.withUnsafeBytes { body.append(contentsOf: $0) }
        let forged = try ChatKATForger().fromInitiator(.attachmentPayload, sequence: harness.nextInitiatorSequence, body: body)
        harness.inject(toResponder: forged)
        #expect(harness.responderAbort?.reason == .payloadMismatch)
        #expect(harness.responderEvents.compactMap(\.receivedAttachment).isEmpty)
        #expect(harness.responder.holdsNothing)
    }

    @Test func payloadWithoutARequestAborts() throws {
        var harness = try ChatHarness.kat()
        let sent = try Self.offered(ChatAttachmentFactory.secret(), harness: &harness)
        var body = Data(sent.id.bytes)
        body.appendBigEndian(UInt32(2))
        body.append(contentsOf: [0x7B, 0x7D])
        let forged = try ChatKATForger().fromInitiator(.attachmentPayload, sequence: harness.nextInitiatorSequence, body: body)
        harness.inject(toResponder: forged)
        #expect(harness.responderAbort?.reason == .unexpectedMessage)
    }

    @Test func payloadLongerThanItsDeclaredLengthAborts() throws {
        var harness = try ChatHarness.kat()
        let sent = try Self.offered(ChatAttachmentFactory.secret(), harness: &harness)
        harness.recordResponder(try harness.responder.requestAttachment(sent.id))
        harness.pump()
        var body = Data(sent.id.bytes)
        body.appendBigEndian(UInt32(1))
        body.append(contentsOf: [0x7B, 0x7D])
        let forged = try ChatKATForger().fromInitiator(.attachmentPayload, sequence: harness.nextInitiatorSequence, body: body)
        harness.inject(toResponder: forged)
        #expect(harness.responderAbort?.reason == .payloadMismatch)
    }

    @Test func payloadOverTheLimitAborts() throws {
        var harness = try ChatHarness.kat()
        let sent = try Self.offered(ChatAttachmentFactory.secret(), harness: &harness)
        harness.recordResponder(try harness.responder.requestAttachment(sent.id))
        harness.pump()
        var body = Data(sent.id.bytes)
        body.appendBigEndian(UInt32(Limits.chatAttachmentBytes + 1))
        body.append(0x7B)
        let forged = try ChatKATForger().fromInitiator(.attachmentPayload, sequence: harness.nextInitiatorSequence, body: body)
        harness.inject(toResponder: forged)
        #expect(harness.responderAbort?.reason == .payloadTooLarge)
    }

    @Test func receivedOfferWithAValueOrSeveralItemsAborts() throws {
        let forger = try ChatKATForger()
        let cases: [(SharePackageModel, NearbyAbortReason)] = [
            (ChatAttachmentFactory.secret(), .invalidPackage(.valueInManifest)),
            (PackageFactory.sample().manifest(), .invalidPackage(.scopeMismatch(.repository))),
        ]
        for (package, reason) in cases {
            var harness = try ChatHarness.kat()
            try harness.runToChatting()
            let json = try SharePackageCoder.encode(package)
            var body = Data(ChatAttachmentID().bytes)
            json.withUnsafeBytes { body.append(contentsOf: $0) }
            harness.inject(toResponder: try forger.fromInitiator(.attachmentOffer, sequence: 1, body: body))
            #expect(harness.responderAbort?.reason == reason)
            #expect(harness.responderEvents.compactMap(\.offerModel).isEmpty)
        }
    }

    @Test func theByteReaderZeroesItsCopyOfABody() throws {
        var reader = NearbyByteReader(Data([0x01, 0x02, 0x03, 0x04]))
        #expect(try reader.byte() == 0x01)
        reader.wipe()
        #expect(reader.remaining() == Data([0x00, 0x00, 0x00]))
    }
}
