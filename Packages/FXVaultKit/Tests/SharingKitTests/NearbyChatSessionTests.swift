import Foundation
import os
import Testing
import VaultCore
@testable import SharingKit

/// ``NearbyChatSession`` over in-memory and relayed transports, with ``ManualClock`` timers.
@Suite("Nearby chat session", .timeLimit(.minutes(1)))
struct NearbyChatSessionTests {
    struct Parties {
        let initiator: NearbyChatSession
        let responder: NearbyChatSession
        let initiatorEvents: EventReader<NearbyChatEvent>
        let responderEvents: EventReader<NearbyChatEvent>
        let initiatorClock = ManualClock()
        let responderClock = ManualClock()

        init(
            initiatorTransport: any NearbyTransport,
            responderTransport: any NearbyTransport,
            initiatorName: String = "Alice's Mac",
            responderName: String = "Bob's Mac"
        ) {
            initiator = NearbyChatSession(
                role: .initiator,
                localName: initiatorName,
                transport: initiatorTransport,
                clock: initiatorClock
            )
            responder = NearbyChatSession(
                role: .responder,
                localName: responderName,
                transport: responderTransport,
                clock: responderClock
            )
            initiatorEvents = EventReader(initiator.events)
            responderEvents = EventReader(responder.events)
        }

        /// Both started; returns both codes (nil if a side ended first).
        func handshake() async throws -> (initiator: NearbySASModel?, responder: NearbySASModel?) {
            try await responder.start()
            try await initiator.start()
            let initiatorSAS = await initiatorEvents.first { $0.sasModel != nil || $0.isTerminal }?.sasModel
            let responderSAS = await responderEvents.first { $0.sasModel != nil || $0.isTerminal }?.sasModel
            await settle()
            return (initiatorSAS, responderSAS)
        }

        /// Handshake and both confirmations; both sides are chatting.
        func verify() async throws {
            _ = try await handshake()
            try await initiator.confirmSAS()
            try await responder.confirmSAS()
            _ = await initiatorEvents.first { $0 == .verified || $0.isTerminal }
            _ = await responderEvents.first { $0 == .verified || $0.isTerminal }
            await settle()
        }

        /// One hop onto each actor: the step that yielded the last event has finished (its
        /// timers were restarted and cancelled ones removed from the clock).
        func settle() async {
            _ = await initiator.phase
            _ = await responder.phase
        }
    }

    /// Waits (yielding) until `condition` holds; the suite time limit bounds it.
    static func eventually(_ condition: () async -> Bool) async {
        while await !condition() {
            await Task.yield()
        }
    }

    // MARK: - Full chat

    @Test func fullChatOverInMemoryTransport() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        try await parties.responder.start()
        try await parties.initiator.start()
        #expect(await parties.responderEvents.next() == .incomingConnection)
        #expect(await parties.responderEvents.next() == .peerConnected(name: "Alice's Mac"))
        #expect(await parties.initiatorEvents.next() == .peerConnected(name: "Bob's Mac"))
        let initiatorSAS = await parties.initiatorEvents.next()?.sasModel
        let responderSAS = await parties.responderEvents.next()?.sasModel
        #expect(initiatorSAS != nil)
        #expect(initiatorSAS?.code == responderSAS?.code)

        try await parties.initiator.confirmSAS()
        try await parties.responder.confirmSAS()
        _ = await parties.initiatorEvents.first { $0 == .verified }
        _ = await parties.responderEvents.first { $0 == .verified }
        #expect(await parties.initiator.phase == .chatting)

        let sent = try await parties.initiator.sendText("Hello Bob")
        #expect(sent.direction == .sent)
        let received = await parties.responderEvents.first { $0.messageModel != nil }?.messageModel
        #expect(received?.text == "Hello Bob")
        #expect(received?.direction == .received)
        try await parties.responder.sendText("Hi Alice")
        #expect(await parties.initiatorEvents.first { $0.messageModel != nil }?.messageModel?.text == "Hi Alice")

        await parties.initiator.close()
        #expect(await parties.responderEvents.rest().last == .peerClosed)
        #expect(await parties.initiatorEvents.rest().isEmpty)
        #expect(await parties.initiator.phase == .closed)
        #expect(await parties.responder.phase == .closed)
        #expect(await parties.initiator.holdsNothing)
        #expect(await parties.responder.holdsNothing)
        await #expect(throws: ChatError.sessionFinished) { try await parties.initiator.sendText("late") }
        await #expect(throws: ChatError.sessionFinished) { try await parties.initiator.start() }
    }

    @Test func attachmentFlowCallsTheProviderOnlyOnRequestAndWipesTheValue() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        try await parties.verify()

        let calls = OSAllocatedUnfairLock(initialState: 0)
        let value = SecretBytes(utf8: "s3cr3t-value")
        let offer = try await parties.initiator.offerAttachment(
            manifest: ChatAttachmentFactory.secret("API_KEY", value: "s3cr3t-value")
        ) {
            calls.withLock { $0 += 1 }
            return value
        }
        let card = await parties.responderEvents.first { $0.offerModel != nil }?.offerModel
        #expect(card?.id == offer.id)
        #expect(card?.itemName == "API_KEY")
        #expect(calls.withLock { $0 } == 0)
        // No frame so far carried the value.
        let needle = Data("s3cr3t-value".utf8)
        #expect(pair.initiator.sentFrames.allSatisfy { $0.range(of: needle) == nil })

        try await parties.responder.requestAttachment(offer.id)
        let delivered = await parties.responderEvents.first { $0.receivedAttachment != nil }?.receivedAttachment
        #expect(delivered?.0 == offer.id)
        #expect(delivered?.1.flattenedItems.first?.item.value?.utf8String() == "s3cr3t-value")
        delivered?.1.wipeValues()
        #expect(await parties.initiatorEvents.first { $0 == .attachmentSent(offer.id) || $0.isTerminal } == .attachmentSent(offer.id))
        await parties.settle()
        #expect(calls.withLock { $0 } == 1)
        #expect(value.isWiped)
        // Encrypted on the wire.
        #expect(pair.initiator.sentFrames.allSatisfy { $0.range(of: needle) == nil })
        await parties.initiator.close()
    }

    @Test func failingProviderWithdrawsTheOffer() async throws {
        struct Unavailable: Error {}
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        try await parties.verify()
        let offer = try await parties.initiator.offerAttachment(manifest: ChatAttachmentFactory.secret()) {
            throw Unavailable()
        }
        _ = await parties.responderEvents.first { $0.offerModel != nil }
        try await parties.responder.requestAttachment(offer.id)
        #expect(await parties.responderEvents.first { $0 == .attachmentDeclined(offer.id) || $0.isTerminal }
            == .attachmentDeclined(offer.id))
        #expect(await parties.initiator.phase == .chatting)
        await parties.responder.close()
    }

    @Test func declineReachesTheSenderAndTheProviderIsDropped() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        try await parties.verify()
        let offer = try await parties.initiator.offerAttachment(manifest: ChatAttachmentFactory.secret()) {
            Issue.record("The provider must not run for a declined offer")
            return SecretBytes(utf8: "unused")
        }
        _ = await parties.responderEvents.first { $0.offerModel != nil }
        try await parties.responder.declineAttachment(offer.id)
        #expect(await parties.initiatorEvents.first { $0 == .attachmentDeclined(offer.id) || $0.isTerminal }
            == .attachmentDeclined(offer.id))
        await parties.initiator.close()
        #expect(await parties.initiator.holdsNothing)
    }

    @Test func closeWipesOffersAndProviders() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        try await parties.verify()
        try await parties.initiator.offerAttachment(manifest: ChatAttachmentFactory.secret()) { SecretBytes(utf8: "v") }
        _ = await parties.responderEvents.first { $0.offerModel != nil }
        #expect(await !parties.initiator.holdsNothing)
        #expect(await !parties.responder.holdsNothing)
        await parties.responder.close()
        #expect(await parties.initiatorEvents.rest().last == .peerClosed)
        #expect(await parties.initiator.holdsNothing)
        #expect(await parties.responder.holdsNothing)
        // The transport is closed once CLOSE went out.
        await Self.eventually { pair.responder.sentFrames.last?.encryptedType == NearbyChatMessageType.close.rawValue }
    }

    // MARK: - MITM

    @Test func mitmOnBothLegsSeesDifferentCodesAndGetsNoPlaintext() async throws {
        // Alice ↔ Mallory (posing as Bob's Mac) and Mallory (posing as Alice's Mac) ↔ Bob.
        let aliceLeg = InMemoryTransportPair()
        let bobLeg = InMemoryTransportPair()
        let alice = Parties(initiatorTransport: aliceLeg.initiator, responderTransport: aliceLeg.responder)
        let bob = Parties(initiatorTransport: bobLeg.initiator, responderTransport: bobLeg.responder)
        let aliceCodes = try await alice.handshake()
        let bobCodes = try await bob.handshake()
        let aliceCode = try #require(aliceCodes.initiator?.code)
        let bobCode = try #require(bobCodes.responder?.code)
        #expect(aliceCode != bobCode)
        // Names can be spoofed; only the code authenticates.
        #expect(aliceCodes.initiator?.peerName == "Bob's Mac")

        // Mallory confirms on both legs at once.
        try await alice.responder.confirmSAS()
        try await bob.initiator.confirmSAS()
        _ = await alice.initiatorEvents.first { $0 == .peerConfirmedSAS }
        // Alice has not confirmed: she cannot send.
        await #expect(throws: ChatError.actionNotAllowed) { try await alice.initiator.sendText("for Bob") }

        // The users see different codes and press "Don't match".
        try await alice.initiator.rejectSAS()
        try await bob.responder.rejectSAS()
        let malloryEvents = await alice.responderEvents.rest() + bob.initiatorEvents.rest()
        #expect(malloryEvents.allSatisfy { $0.messageModel == nil && $0.offerModel == nil })
        #expect(malloryEvents.contains { $0.abortModel?.reason == .peerAborted(.sasRejected) })
        let textType = NearbyChatMessageType.text.rawValue
        #expect(!aliceLeg.initiator.sentFrames.contains { $0.encryptedType == textType })
        #expect(!bobLeg.responder.sentFrames.contains { $0.encryptedType == textType })
    }

    @Test func keySubstitutingRelayFailsConfirmAndDeliversNothing() async throws {
        let mallory = try NearbyMITMTests.malloryMaterial(0xC0)
        let relay = RelayTransport { direction, frame in
            guard direction == .toInitiator, frame.first == NearbyMessageType.helloResponder.rawValue else {
                return [frame]
            }
            var tampered = frame
            tampered.replaceSubrange(3..<35, with: mallory.publicKey)
            return [tampered]
        }
        relay.start()
        let parties = Parties(initiatorTransport: relay.initiatorTransport, responderTransport: relay.responderTransport)
        let codes = try await parties.handshake()
        #expect(codes.initiator?.code != codes.responder?.code)
        // Careless users confirm anyway: the responder cannot open the initiator's CONFIRM.
        try await parties.initiator.confirmSAS()
        try await parties.responder.confirmSAS()
        let responderAbort = await parties.responderEvents.first { $0.isTerminal }?.abortModel
        #expect(responderAbort?.reason == .decryptionFailed)
        #expect(responderAbort?.suggestsInterception == true)
        let initiatorEnd = await parties.initiatorEvents.rest()
        #expect(!initiatorEnd.contains(.verified))
        #expect(initiatorEnd.last?.isTerminal == true)
        await #expect(throws: ChatError.sessionFinished) { try await parties.initiator.sendText("secret") }
    }

    @Test func relayReplayingATextAbortsTheReceiver() async throws {
        let relay = RelayTransport { direction, frame in
            direction == .toResponder && frame.encryptedType == NearbyChatMessageType.text.rawValue ? [frame, frame] : [frame]
        }
        relay.start()
        let parties = Parties(initiatorTransport: relay.initiatorTransport, responderTransport: relay.responderTransport)
        try await parties.verify()
        try await parties.initiator.sendText("once")
        let events = await parties.responderEvents.rest()
        #expect(events.compactMap(\.messageModel).map(\.text) == ["once"])
        #expect(events.last?.abortModel?.reason == .sequenceMismatch)
    }

    // MARK: - Purpose confusion

    @Test func shareInitiatorIsRejectedByAChatResponder() async throws {
        let pair = InMemoryTransportPair()
        let share = NearbySession(role: .initiator, localName: "Alice's Mac", transport: pair.initiator, clock: ManualClock())
        let chat = NearbyChatSession(role: .responder, localName: "Bob's Mac", transport: pair.responder, clock: ManualClock())
        let shareEvents = EventReader(share.events)
        let chatEvents = EventReader(chat.events)
        try await chat.start()
        try await share.start()
        let chatAbort = await chatEvents.first { $0.isTerminal }?.abortModel
        #expect(chatAbort?.reason == .commitmentMismatch)
        #expect(chatAbort?.suggestsInterception == true)
        let shareAbort = await shareEvents.first { $0.isAbort }?.abortModel
        #expect(shareAbort?.reason == .peerAborted(.commitmentMismatch))
        #expect(await chat.sas == nil)
        #expect(await chat.holdsNothing)
    }

    @Test func chatInitiatorIsRejectedByAShareResponder() async throws {
        let pair = InMemoryTransportPair()
        let chat = NearbyChatSession(role: .initiator, localName: "Alice's Mac", transport: pair.initiator, clock: ManualClock())
        let share = NearbySession(role: .responder, localName: "Bob's Mac", transport: pair.responder, clock: ManualClock())
        let chatEvents = EventReader(chat.events)
        let shareEvents = EventReader(share.events)
        try await share.start()
        try await chat.start()
        #expect(await shareEvents.first { $0.isAbort }?.abortModel?.reason == .commitmentMismatch)
        #expect(await chatEvents.first { $0.isTerminal }?.abortModel?.reason == .peerAborted(.commitmentMismatch))
        #expect(await share.phase == .aborted)
        #expect(await chat.phase == .aborted)
    }

    // MARK: - Timers

    @Test func responderWaitsForAPeerWithoutATimer() async throws {
        let transport = InMemoryTransport()
        let clock = ManualClock()
        let responder = NearbyChatSession(role: .responder, localName: "Bob's Mac", transport: transport, clock: clock)
        let events = EventReader(responder.events)
        try await responder.start()
        #expect(NearbyChatSession.timeoutKind(phase: .awaitingPeer, role: .responder) == nil)
        #expect(NearbyChatSession.timeoutKind(phase: .awaitingPeer, role: .initiator) == .handshake)
        clock.advance(by: Timeouts.chatIdle)
        #expect(await responder.phase == .awaitingPeer)
        #expect(clock.sleeperCount == 0)

        // Once a peer connects, the handshake must finish in time.
        transport.inject(.connected)
        await clock.waitForSleepers(count: 1)
        #expect(await responder.phase == .awaitingHello)
        clock.advance(by: Timeouts.nearbyHandshake)
        #expect(await events.first { $0.isTerminal }?.abortModel?.reason == .timeout(.handshake))
    }

    @Test func sasTimeout() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        _ = try await parties.handshake()
        await parties.responderClock.waitForSleepers(count: 1)
        parties.responderClock.advance(by: Timeouts.nearbySAS)
        #expect(await parties.responderEvents.first { $0.isTerminal }?.abortModel?.reason == .timeout(.sas))
        #expect(await parties.initiatorEvents.first { $0.isTerminal }?.abortModel?.reason == .peerAborted(.timeout))
    }

    @Test func keepaliveIsAnsweredAndAnUnresponsivePeerTimesOut() async throws {
        let dropping = OSAllocatedUnfairLock(initialState: false)
        let relay = RelayTransport { direction, frame in
            direction == .toResponder && dropping.withLock { $0 } ? [] : [frame]
        }
        relay.start()
        let parties = Parties(initiatorTransport: relay.initiatorTransport, responderTransport: relay.responderTransport)
        try await parties.verify()
        let clock = parties.responderClock
        await clock.waitForSleepers(count: 2) // chat idle + keepalive

        // A PING every interval; the peer answers each one.
        for _ in 0..<Limits.chatMaxUnansweredPings + 1 {
            clock.advance(by: Timeouts.chatKeepaliveInterval)
            await clock.waitForSleepers(count: 2)
            await Self.eventually { await parties.responder.unansweredPingCount == 0 }
        }
        #expect(await parties.responder.phase == .chatting)

        // The initiator goes silent (out of range): its PONGs no longer arrive.
        dropping.withLock { $0 = true }
        for _ in 0..<Limits.chatMaxUnansweredPings {
            clock.advance(by: Timeouts.chatKeepaliveInterval)
            await clock.waitForSleepers(count: 2)
        }
        #expect(await parties.responder.phase == .chatting)
        clock.advance(by: Timeouts.chatKeepaliveInterval)
        let abort = await parties.responderEvents.first { $0.isTerminal }?.abortModel
        #expect(abort?.reason == .timeout(.keepalive))
        #expect(abort?.isSecurityRelevant == false)
        #expect(await parties.responder.holdsNothing)
    }

    @Test func idleChatEndsAndMessagesRestartTheIdleTimer() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        try await parties.verify()
        let clock = parties.responderClock
        let almostIdle = Timeouts.chatIdle - .seconds(Timeouts.secondsPerMinute)
        await clock.waitForSleepers(count: 2)

        clock.advance(by: almostIdle)
        await clock.waitForSleepers(count: 2)
        await Self.eventually { await parties.responder.unansweredPingCount == 0 }
        #expect(await parties.responder.phase == .chatting)

        // A message restarts the idle timer.
        try await parties.initiator.sendText("still here")
        _ = await parties.responderEvents.first { $0.messageModel != nil }
        await parties.settle()
        await clock.waitForSleepers(count: 2)

        clock.advance(by: almostIdle)
        await clock.waitForSleepers(count: 2)
        await Self.eventually { await parties.responder.unansweredPingCount == 0 }
        #expect(await parties.responder.phase == .chatting)

        clock.advance(by: .seconds(Timeouts.secondsPerMinute))
        let abort = await parties.responderEvents.first { $0.isTerminal }?.abortModel
        #expect(abort?.reason == .timeout(.chatIdle))
        let rest = await parties.initiatorEvents.rest()
        #expect(rest.last?.abortModel?.reason == .peerAborted(.timeout), "\(rest)")
    }

    // MARK: - Transport events

    @Test func disconnectAbortsAndWipes() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        try await parties.verify()
        try await parties.initiator.offerAttachment(manifest: ChatAttachmentFactory.secret()) { SecretBytes(utf8: "v") }
        pair.responder.close()
        let abort = await parties.initiatorEvents.first { $0.isTerminal }?.abortModel
        #expect(abort?.reason == .disconnected)
        #expect(abort?.happenedAfterReveal == true)
        #expect(await parties.initiator.holdsNothing)
        #expect(await parties.initiator.phase == .aborted)
    }

    @Test func secondPeerAborts() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        try await parties.verify()
        pair.responder.inject(.secondPeer)
        #expect(await parties.responderEvents.first { $0.isTerminal }?.abortModel?.reason == .secondPeer)
        #expect(await parties.initiatorEvents.first { $0.isTerminal }?.abortModel?.reason == .peerAborted(.cancelled))
    }
}
