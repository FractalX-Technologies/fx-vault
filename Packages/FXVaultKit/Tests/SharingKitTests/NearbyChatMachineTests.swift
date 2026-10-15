import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// The pure `fxvault-chat/v1` state machine, driven frame by frame.
@Suite("Nearby chat state machine")
struct NearbyChatMachineTests {
    // MARK: - Handshake and messages

    @Test func fullChatExchangesMessagesBothWays() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        #expect(harness.initiatorEvents.first == .peerConnected(name: "Bob's Mac"))
        // The responder learns of the connection first, then of the peer's (unverified) name.
        #expect(Array(harness.responderEvents.prefix(2)) == [.incomingConnection, .peerConnected(name: "Alice's Mac")])
        #expect(!harness.initiatorEvents.contains(.incomingConnection))
        #expect(harness.initiatorEvents.contains(.verified))
        #expect(harness.responderEvents.contains(.verified))
        #expect(harness.initiatorEvents.contains(.peerConfirmedSAS))

        let sent = try harness.sendFromInitiator("  Hi Bob  ")
        #expect(sent?.text == "Hi Bob")
        #expect(sent?.direction == .sent)
        try harness.sendFromResponder("Hi Alice 👋")
        try harness.sendFromInitiator("line one\r\nline two")

        #expect(harness.responderMessages.map(\.text) == ["Hi Bob", "line one\nline two"])
        #expect(harness.responderMessages.allSatisfy { $0.direction == .received && $0.date == ChatHarness.date })
        #expect(harness.initiatorMessages.map(\.text) == ["Hi Alice 👋"])
        #expect(harness.initiatorAbort == nil)
        #expect(harness.responderAbort == nil)
    }

    @Test func nothingIsSentBeforeBothUsersConfirm() throws {
        var harness = try ChatHarness.kat()
        try harness.runHandshake()
        #expect(throws: ChatError.actionNotAllowed) { _ = try harness.initiator.sendText("hello", at: ChatHarness.date) }
        harness.recordInitiator(try harness.initiator.confirmSAS())
        harness.pump()
        // Only the initiator confirmed: still no chat.
        #expect(harness.initiator.phase == .comparingCodes)
        #expect(throws: ChatError.actionNotAllowed) { _ = try harness.initiator.sendText("hello", at: ChatHarness.date) }
        #expect(throws: ChatError.actionNotAllowed) { _ = try harness.initiator.confirmSAS() }

        // A TEXT forged with the right key before the responder confirmed is rejected.
        let forged = try ChatKATForger().fromInitiator(.text, sequence: 1, body: Data("early".utf8))
        harness.inject(toResponder: forged)
        #expect(harness.responderAbort?.reason == .unexpectedMessage)
        #expect(harness.responderMessages.isEmpty)
    }

    @Test func dontMatchAbortsBothSides() throws {
        var harness = try ChatHarness.kat()
        try harness.runHandshake()
        harness.recordResponder(try harness.responder.rejectSAS())
        harness.pump()
        #expect(harness.responderAbort?.reason == .sasRejected)
        #expect(harness.initiatorAbort?.reason == .peerAborted(.sasRejected))
        #expect(harness.initiatorAbort?.suggestsInterception == true)
    }

    @Test func receivedTextIsSanitizedAndChecked() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        let forger = try ChatKATForger()
        // Bidi override and zero-width space removed; the emoji joiner kept.
        let tricky = "pay\u{202E}lapyap\u{200B} 👩\u{200D}💻"
        harness.inject(toResponder: try forger.fromInitiator(.text, sequence: 1, body: Data(tricky.utf8)))
        #expect(harness.responderMessages.map(\.text) == ["paylapyap 👩\u{200D}💻"])
        // Only invisible characters: no message, but no abort either.
        harness.inject(toResponder: try forger.fromInitiator(.text, sequence: 2, body: Data("\u{200B}\u{202E}".utf8)))
        #expect(harness.responderMessages.count == 1)
        #expect(harness.responderAbort == nil)
        // Invalid UTF-8 aborts.
        harness.inject(toResponder: try forger.fromInitiator(.text, sequence: 3, body: Data([0xC3, 0x28])))
        #expect(harness.responderAbort?.reason == .malformedFrame)
    }

    @Test func emptyTextFrameAborts() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        harness.inject(toResponder: try ChatKATForger().fromInitiator(.text, sequence: 1, body: Data()))
        #expect(harness.responderAbort?.reason == .malformedFrame)
    }

    @Test func sendTextChecksEmptyAndSize() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        #expect(throws: ChatError.emptyMessage) { _ = try harness.initiator.sendText(" \n\u{200B} ", at: ChatHarness.date) }
        let limit = String(repeating: "a", count: Limits.chatMessageBytes)
        #expect(try harness.sendFromInitiator(limit)?.text == limit)
        #expect(throws: ChatError.messageTooLarge) {
            _ = try harness.initiator.sendText(limit + "a", at: ChatHarness.date)
        }
        #expect(harness.responderMessages.map(\.text) == [limit])
    }

    // MARK: - Oversize, replay, reorder, truncation

    @Test func oversizeTextAborts() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        let body = Data(repeating: 0x61, count: Limits.chatMessageBytes + 1)
        harness.inject(toResponder: try ChatKATForger().fromInitiator(.text, sequence: 1, body: body))
        #expect(harness.responderAbort?.reason == .oversizeFrame)
        #expect(harness.responderMessages.isEmpty)
    }

    @Test func oversizeFrameAborts() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        let frame = Data([NearbyProtocol.maxVersion, NearbyChatMessageType.text.rawValue])
            + Data(count: Limits.maxNearbyEncryptedFrameBytes)
        harness.inject(toResponder: frame)
        #expect(harness.responderAbort?.reason == .oversizeFrame)
    }

    @Test func replayedTextAborts() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        try harness.sendFromInitiator("once")
        let text = try #require(harness.initiatorFrames.last)
        harness.inject(toResponder: text)
        #expect(harness.responderAbort?.reason == .sequenceMismatch)
        #expect(harness.responderMessages.map(\.text) == ["once"])
        #expect(harness.initiatorAbort?.reason == .peerAborted(.protocolError))
    }

    @Test func reorderedTextAborts() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        var held: [Data] = []
        harness.interceptToResponder = { frame in
            if frame.encryptedType == NearbyChatMessageType.text.rawValue, held.isEmpty {
                held.append(frame)
                return []
            }
            return [frame]
        }
        try harness.sendFromInitiator("first")
        try harness.sendFromInitiator("second")
        #expect(harness.responderAbort?.reason == .sequenceMismatch)
        #expect(harness.responderMessages.isEmpty)
        let first = try #require(held.first)
        harness.inject(toResponder: first)
        #expect(harness.responderMessages.isEmpty)
    }

    @Test func truncatedFramesAbort() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        harness.interceptToResponder = { [$0.dropLast()] }
        try harness.sendFromInitiator("cut")
        #expect(harness.responderAbort?.reason == .decryptionFailed)
        #expect(harness.responderMessages.isEmpty)

        var second = try ChatHarness.kat()
        try second.runToChatting()
        // An authenticated offer too short to hold an id.
        second.inject(toResponder: try ChatKATForger().fromInitiator(.attachmentOffer, sequence: 1, body: Data([1, 2, 3])))
        #expect(second.responderAbort?.reason == .malformedFrame)
    }

    @Test func reflectedFrameFailsAuthentication() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        let (step, _) = try harness.initiator.sendText("echo", at: ChatHarness.date)
        let frame = try #require(step.frames.first)
        harness.inject(toInitiator: frame)
        #expect(harness.initiatorAbort?.reason == .decryptionFailed)
    }

    @Test func shareMessageTypesAreRejectedInAChat() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        let manifest = try ChatKATForger().fromInitiator(
            .text,
            sequence: 1,
            body: Data("x".utf8)
        )
        var asShareType = manifest
        asShareType[1] = NearbyMessageType.manifest.rawValue // the type is in the AAD
        harness.inject(toResponder: asShareType)
        #expect(harness.responderAbort?.reason == .decryptionFailed)

        var second = try ChatHarness.kat()
        try second.runToChatting()
        let forger = try ChatKATForger()
        let shareFrame = try NearbyEncryptedFrame.seal(
            type: .manifest,
            sequence: 1,
            body: Data([0, 0, 0, 1, 0x7B]),
            key: forger.initiatorToResponder
        )
        second.inject(toResponder: shareFrame)
        #expect(second.responderAbort?.reason == .unexpectedMessage)
    }

    // MARK: - Purpose confusion

    @Test func shareInitiatorCannotOpenAChat() throws {
        let kat = try ChatKAT.load()
        var share = NearbyHandshake(role: .initiator, localName: kat.inputs.nameI, keyMaterial: try kat.keyMaterial(.initiator))
        var chat = NearbyChatMachine(role: .responder, localName: kat.inputs.nameR, keyMaterial: try kat.keyMaterial(.responder))
        _ = try chat.start()
        _ = chat.transportConnected()
        let helloI = try #require(try share.start().frames.first)
        let helloR = try #require(chat.receive(helloI, at: ChatHarness.date).frames.first)
        let reveal = share.receive(helloR)
        #expect(share.phase == .comparingCodes) // the share side cannot tell yet
        let revealFrame = try #require(reveal.frames.first)
        let chatStep = chat.receive(revealFrame, at: ChatHarness.date)
        #expect(chatStep.abortReason == .commitmentMismatch)
        #expect(chat.sas == nil)
        #expect(chat.phase == .aborted)
        // The share initiator gets the plaintext ABORT and never reaches a transfer.
        let abortFrame = try #require(chatStep.frames.first)
        #expect(share.receive(abortFrame).abortReason == .peerAborted(.commitmentMismatch))
    }

    @Test func chatInitiatorCannotOpenAShare() throws {
        let kat = try ChatKAT.load()
        var chat = NearbyChatMachine(role: .initiator, localName: kat.inputs.nameI, keyMaterial: try kat.keyMaterial(.initiator))
        var share = NearbyHandshake(role: .responder, localName: kat.inputs.nameR, keyMaterial: try kat.keyMaterial(.responder))
        _ = try share.start()
        _ = try chat.start()
        let helloI = try #require(chat.transportConnected().frames.first)
        let helloR = try #require(share.receive(helloI).frames.first)
        let reveal = try #require(chat.receive(helloR, at: ChatHarness.date).frames.first)
        let shareStep = share.receive(reveal)
        #expect(shareStep.abortReason == .commitmentMismatch)
        #expect(share.sas == nil)
        #expect(share.receive(Data([0x01])) == .none) // terminal
    }

    @Test func purposesNeverAgreeEvenWithoutTheCommitmentCheck() throws {
        // A relay that forwards a share REVEAL to a chat responder would still need matching
        // keys: the chat and share keys differ, so a CONFIRM from one never opens in the other.
        let kat = try ChatKAT.load()
        var shareHarness = try HandshakeHarness.kat()
        try shareHarness.runHandshake()
        var chatHarness = try ChatHarness.kat()
        try chatHarness.runHandshake()
        #expect(shareHarness.initiator.sas?.code != chatHarness.initiator.sas?.code)
        #expect(chatHarness.initiator.sas?.code == (try kat.output("SAS")))
        let shareConfirm = try #require(try shareHarness.initiator.confirmSAS().frames.first)
        chatHarness.inject(toResponder: shareConfirm)
        #expect(chatHarness.responderAbort?.reason == .decryptionFailed)
    }

    @Test func keySubstitutionWithoutThePrivateKeyFailsConfirm() throws {
        let mallory = try NearbyMITMTests.malloryMaterial(0xC0)
        var harness = try ChatHarness.kat()
        harness.interceptToInitiator = { frame in
            guard frame.first == NearbyMessageType.helloResponder.rawValue else { return [frame] }
            var tampered = frame
            tampered.replaceSubrange(3..<35, with: mallory.publicKey)
            return [tampered]
        }
        try harness.runHandshake()
        #expect(harness.initiator.sas?.code != harness.responder.sas?.code)
        harness.recordInitiator(try harness.initiator.confirmSAS())
        harness.pump()
        #expect(harness.responderAbort?.reason == .decryptionFailed)
        #expect(harness.responder.phase == .aborted)
    }

    // MARK: - Keepalive

    @Test func pingIsAnsweredAndUnansweredPingsAbort() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        harness.recordInitiator(harness.initiator.keepaliveTick())
        harness.pump()
        #expect(harness.responderFrames.last?.encryptedType == NearbyChatMessageType.pong.rawValue)

        // The peer stops answering: two PINGs go unanswered, the third tick aborts.
        harness.interceptToResponder = { _ in [] }
        for _ in 0..<Limits.chatMaxUnansweredPings {
            harness.recordInitiator(harness.initiator.keepaliveTick())
            #expect(harness.initiator.phase == .chatting)
        }
        let step = harness.initiator.keepaliveTick()
        #expect(step.abortReason == .timeout(.keepalive))
        #expect(step.frames.count == 1) // encrypted ABORT
    }

    @Test func unsolicitedPongAndPingWithBodyAbort() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        let forger = try ChatKATForger()
        harness.inject(toResponder: try forger.fromInitiator(.pong, sequence: 1, body: Data()))
        #expect(harness.responderAbort?.reason == .unexpectedMessage)

        var second = try ChatHarness.kat()
        try second.runToChatting()
        second.inject(toResponder: try forger.fromInitiator(.ping, sequence: 1, body: Data([0])))
        #expect(second.responderAbort?.reason == .malformedFrame)
    }

    // MARK: - Flood limits

    @Test func aMessageFloodAborts() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        for index in 0...Limits.chatMaxPeerFramesPerFloodWindow {
            try harness.sendFromInitiator("message \(index)")
        }
        #expect(harness.responderMessages.count == Limits.chatMaxPeerFramesPerFloodWindow)
        #expect(harness.responderAbort?.reason == .unexpectedMessage)
        #expect(harness.initiatorAbort?.reason == .peerAborted(NearbyAbortReason.unexpectedMessage.code))
    }

    @Test func messagesAtTheLimitRateNeverAbort() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        let limit = Limits.chatMaxPeerFramesPerFloodWindow
        let spacing = Timeouts.chatFloodWindow.timeInterval / Double(limit)
        for index in 0..<(limit * 3) {
            let (step, _) = try harness.initiator.sendText("message \(index)", at: ChatHarness.date)
            let arrival = ChatHarness.date.addingTimeInterval(Double(index) * spacing)
            for frame in step.frames {
                harness.recordResponder(harness.responder.receive(frame, at: arrival))
            }
        }
        #expect(harness.responderAbort == nil)
        #expect(harness.responderMessages.count == limit * 3)
    }

    @Test func aPingFloodAborts() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        let forger = try ChatKATForger()
        // The PONGs never reach the initiator (its unsolicited-PONG rule would abort first).
        harness.interceptToInitiator = { _ in [] }
        var sequence = harness.nextInitiatorSequence
        for _ in 0...Limits.chatMaxPeerFramesPerFloodWindow where harness.responderAbort == nil {
            harness.inject(toResponder: try forger.fromInitiator(.ping, sequence: sequence, body: Data()))
            sequence += 1
        }
        #expect(harness.responderAbort?.reason == .unexpectedMessage)
    }

    @Test func offeringAndWithdrawingForeverAborts() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        for _ in 0..<Limits.chatMaxOffersPerChat {
            let (step, offer) = try harness.initiator.offerAttachment(ChatAttachmentFactory.secret())
            harness.recordInitiator(step)
            harness.pump()
            harness.recordInitiator(harness.initiator.withdrawAttachment(try #require(offer).id))
            harness.pump()
        }
        #expect(harness.responderAbort == nil)
        let (step, _) = try harness.initiator.offerAttachment(ChatAttachmentFactory.secret())
        harness.recordInitiator(step)
        harness.pump()
        #expect(harness.responderAbort?.reason == .unexpectedMessage)
        #expect(harness.responderEvents.compactMap(\.offerModel).count == Limits.chatMaxOffersPerChat)
    }

    // MARK: - Close

    @Test func closeEndsBothSidesAndWipes() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        let (offerStep, _) = try harness.initiator.offerAttachment(ChatAttachmentFactory.secret())
        harness.recordInitiator(offerStep)
        harness.pump()
        #expect(!harness.initiator.holdsNothing)
        #expect(!harness.responder.holdsNothing)

        harness.recordInitiator(harness.initiator.close())
        harness.pump()
        #expect(harness.initiator.phase == .closed)
        #expect(harness.responder.phase == .closed)
        #expect(harness.responderEvents.last == .peerClosed)
        #expect(harness.initiator.holdsNothing)
        #expect(harness.responder.holdsNothing)
        #expect(throws: ChatError.sessionFinished) { _ = try harness.initiator.sendText("late", at: ChatHarness.date) }
        #expect(harness.initiator.close() == .none)
        #expect(harness.responder.receive(Data([0x01, 0x20]), at: ChatHarness.date) == .none)
    }

    @Test func closeBeforeVerificationAbortsAsCancelled() throws {
        var harness = try ChatHarness.kat()
        try harness.runHandshake()
        harness.recordResponder(harness.responder.close())
        harness.pump()
        #expect(harness.responderAbort?.reason == .cancelled)
        #expect(harness.initiatorAbort?.reason == .peerAborted(.cancelled))
        #expect(harness.initiatorAbort?.suggestsInterception == false)

        var idle = NearbyChatMachine(role: .responder, localName: "R")
        #expect(idle.close() == .none)
        #expect(idle.phase == .closed)
        // Waiting for a peer: closing the window ends silently (no abort, no frame).
        var waiting = NearbyChatMachine(role: .responder, localName: "R")
        _ = try waiting.start()
        #expect(waiting.close() == .none)
        #expect(waiting.phase == .closed)
        #expect(waiting.transportConnected() == .none)
    }

    @Test func closeWipesAPartialPayload() throws {
        var harness = try ChatHarness.kat()
        try harness.runToChatting()
        // A value large enough to span two frames once JSON-escaped.
        let value = String(repeating: "\"", count: Limits.maxValueBytes)
        let (offerStep, offer) = try harness.initiator.offerAttachment(ChatAttachmentFactory.secret(value: value))
        harness.recordInitiator(offerStep)
        harness.pump()
        let id = try #require(offer?.id)
        harness.recordResponder(try harness.responder.requestAttachment(id))
        harness.pump()
        let payload = try harness.initiator.sendAttachmentPayload(id, value: SecretBytes(utf8: value))
        #expect(payload.frames.count >= 2)
        let first = try #require(payload.frames.first)
        harness.inject(toResponder: first)
        #expect(!harness.responder.holdsNothing)
        #expect(harness.responderEvents.compactMap(\.receivedAttachment).isEmpty)
        harness.recordResponder(harness.responder.close())
        #expect(harness.responder.holdsNothing)
    }

    @Test func peerAbortAndCloseBeforeChattingAreFinal() throws {
        var harness = try ChatHarness.kat()
        try harness.runHandshake()
        // CLOSE during the code comparison is a cancel, not a normal end.
        harness.inject(toResponder: try ChatKATForger().fromInitiator(.close, sequence: 0, body: Data()))
        #expect(harness.responderAbort?.reason == .peerAborted(.cancelled))
        #expect(throws: ChatError.sessionFinished) { _ = try harness.responder.confirmSAS() }
    }
}
