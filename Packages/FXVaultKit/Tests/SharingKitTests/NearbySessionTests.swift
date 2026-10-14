import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// ``NearbySession`` over in-memory and relayed transports, with ``ManualClock`` timers.
@Suite("Nearby session", .timeLimit(.minutes(1)))
struct NearbySessionTests {
    struct Parties {
        let initiator: NearbySession
        let responder: NearbySession
        let initiatorEvents: EventReader<NearbyEvent>
        let responderEvents: EventReader<NearbyEvent>
        let initiatorClock: ManualClock
        let responderClock: ManualClock

        init(initiatorTransport: any NearbyTransport, responderTransport: any NearbyTransport) {
            initiatorClock = ManualClock()
            responderClock = ManualClock()
            initiator = NearbySession(
                role: .initiator,
                localName: "Alice's Mac",
                transport: initiatorTransport,
                clock: initiatorClock
            )
            responder = NearbySession(
                role: .responder,
                localName: "Bob's Mac",
                transport: responderTransport,
                clock: responderClock
            )
            initiatorEvents = EventReader(initiator.events)
            responderEvents = EventReader(responder.events)
        }

        /// Both started; returns both codes.
        func handshake() async throws -> (initiator: NearbySASModel?, responder: NearbySASModel?) {
            try await responder.start()
            try await initiator.start()
            let initiatorSAS = await initiatorEvents.first { $0.sasModel != nil || $0.isTerminal }?.sasModel
            let responderSAS = await responderEvents.first { $0.sasModel != nil || $0.isTerminal }?.sasModel
            return (initiatorSAS, responderSAS)
        }

        func confirmBoth() async throws {
            try await initiator.confirmSAS()
            try await responder.confirmSAS()
            _ = await initiatorEvents.first { $0 == .readyForManifest }
        }
    }

    // MARK: - Full run

    @Test func fullRunOverInMemoryTransport() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        let codes = try await parties.handshake()
        #expect(codes.initiator?.code == codes.responder?.code)
        #expect(codes.initiator?.peerName == "Bob's Mac")
        #expect(codes.responder?.peerName == "Alice's Mac")

        try await parties.confirmBoth()
        let package = PackageFactory.sample()
        try await parties.initiator.sendManifest(package)
        let manifestEvent = await parties.responderEvents.first {
            if case .manifestReceived = $0 { return true }
            return $0.isTerminal
        }
        guard case .manifestReceived(let manifest) = manifestEvent else {
            Issue.record("No manifest: \(String(describing: manifestEvent))")
            return
        }
        #expect(manifest.flattenedItems.allSatisfy { $0.item.value == nil })

        let decision = NearbyDecisionModel(accept: true, itemIDs: manifest.allEntryIDs)
        try await parties.responder.sendDecision(decision)
        let decisionEvent = await parties.initiatorEvents.first { $0 == .decisionReceived(decision) || $0.isTerminal }
        #expect(decisionEvent == .decisionReceived(decision))

        try await parties.initiator.sendPayload(package)
        let payloadEvent = await parties.responderEvents.first {
            if case .payloadReceived = $0 { return true }
            return $0.isTerminal
        }
        guard case .payloadReceived(let payload) = payloadEvent else {
            Issue.record("No payload: \(String(describing: payloadEvent))")
            return
        }
        #expect(payload.flattenedItems.map { $0.item.value?.utf8String() }
            == package.flattenedItems.map { $0.item.value?.utf8String() })

        try await parties.responder.sendResult(ok: true)
        #expect(await parties.responderEvents.rest().last == .completed(.resultSent(ok: true)))
        #expect(await parties.initiatorEvents.rest().last == .completed(.transferred(receiverOK: true)))
        #expect(await parties.initiator.phase == .finished)
        #expect(await parties.responder.phase == .finished)
    }

    @Test func transparentRelayStillMatches() async throws {
        let relay = RelayTransport()
        relay.start()
        let parties = Parties(initiatorTransport: relay.initiatorTransport, responderTransport: relay.responderTransport)
        let codes = try await parties.handshake()
        #expect(codes.initiator != nil)
        #expect(codes.initiator?.code == codes.responder?.code)
        await parties.initiator.cancel()
    }

    // MARK: - Relay attacks at the session level

    @Test func relayReplayingAFrameAbortsTheReceiver() async throws {
        let relay = RelayTransport { direction, frame in
            let isConfirm = frame.count > 1 && frame[0] == NearbyProtocol.maxVersion
                && frame[1] == NearbyMessageType.confirm.rawValue
            return direction == .toResponder && isConfirm ? [frame, frame] : [frame]
        }
        relay.start()
        let parties = Parties(initiatorTransport: relay.initiatorTransport, responderTransport: relay.responderTransport)
        _ = try await parties.handshake()
        try await parties.initiator.confirmSAS()
        let responderAbort = await parties.responderEvents.first { $0.isTerminal }?.abortModel
        #expect(responderAbort?.reason == .sequenceMismatch)
        let initiatorAbort = await parties.initiatorEvents.first { $0.isTerminal }?.abortModel
        #expect(initiatorAbort?.reason == .peerAborted(.protocolError))
    }

    @Test func relayTamperingWithACipherTextAborts() async throws {
        let relay = RelayTransport { direction, frame in
            guard direction == .toResponder, frame.count > 1, frame[0] == NearbyProtocol.maxVersion,
                  frame[1] == NearbyMessageType.confirm.rawValue
            else { return [frame] }
            var tampered = frame
            tampered[NearbyProtocol.encryptedHeaderBytes] ^= 0xFF
            return [tampered]
        }
        relay.start()
        let parties = Parties(initiatorTransport: relay.initiatorTransport, responderTransport: relay.responderTransport)
        _ = try await parties.handshake()
        try await parties.initiator.confirmSAS()
        let responderAbort = await parties.responderEvents.first { $0.isTerminal }?.abortModel
        #expect(responderAbort?.reason == .decryptionFailed)
        #expect(responderAbort?.suggestsInterception == true)
    }

    // MARK: - Timeouts

    @Test func handshakeTimeout() async throws {
        let pair = InMemoryTransportPair()
        let clock = ManualClock()
        let initiator = NearbySession(role: .initiator, localName: "I", transport: pair.initiator, clock: clock)
        let events = EventReader(initiator.events)
        try await initiator.start()
        await clock.waitForSleepers(count: 2) // session + handshake
        clock.advance(by: Timeouts.nearbyHandshake)
        let abort = await events.first { $0.isTerminal }?.abortModel
        #expect(abort?.reason == .timeout(.handshake))
        #expect(abort?.happenedAfterReveal == false)
        // The peer sees HELLO_I, a plaintext ABORT and the close; nothing is retried.
        let peerEvents = await pair.responder.events.collect()
        let frames = peerEvents.compactMap { event -> Data? in
            if case .received(let frame) = event { return frame }
            return nil
        }
        #expect(frames.map(\.first) == [NearbyMessageType.helloInitiator.rawValue, NearbyMessageType.abort.rawValue])
        #expect(peerEvents.last == .disconnected)
    }

    @Test func sasTimeout() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        _ = try await parties.handshake()
        await parties.initiatorClock.waitForSleepers(count: 2) // session + SAS
        parties.initiatorClock.advance(by: Timeouts.nearbySAS)
        #expect(await parties.initiatorEvents.first { $0.isTerminal }?.abortModel?.reason == .timeout(.sas))
        #expect(await parties.responderEvents.first { $0.isTerminal }?.abortModel?.reason == .peerAborted(.timeout))
    }

    @Test func sasTimerFiresExactlyAtTheLimit() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        _ = try await parties.handshake()
        await parties.initiatorClock.waitForSleepers(count: 2)
        parties.initiatorClock.advance(by: Timeouts.nearbySAS - .seconds(1))
        // advance(by:) resumes due sleepers synchronously: both timers are still waiting.
        #expect(parties.initiatorClock.sleeperCount == 2)
        parties.initiatorClock.advance(by: .seconds(1))
        #expect(await parties.initiatorEvents.first { $0.isTerminal }?.abortModel?.reason == .timeout(.sas))
    }

    @Test func idleTimeoutWhileWaitingForPayload() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        _ = try await parties.handshake()
        try await parties.confirmBoth()
        let package = PackageFactory.sample()
        try await parties.initiator.sendManifest(package)
        let manifestEvent = await parties.responderEvents.first {
            if case .manifestReceived = $0 { return true }
            return $0.isTerminal
        }
        guard case .manifestReceived(let manifest) = manifestEvent else {
            Issue.record("No manifest")
            return
        }
        try await parties.responder.sendDecision(NearbyDecisionModel(accept: true, itemIDs: manifest.allEntryIDs))
        // The sender never sends the payload.
        await parties.responderClock.waitForSleepers(count: 2) // session + idle
        parties.responderClock.advance(by: Timeouts.nearbyIdle)
        #expect(await parties.responderEvents.first { $0.isTerminal }?.abortModel?.reason == .timeout(.idle))
    }

    @Test func sessionTimeoutWhileWaitingForADecision() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        _ = try await parties.handshake()
        try await parties.confirmBoth()
        try await parties.initiator.sendManifest(PackageFactory.sample())
        #expect(await parties.initiator.phase == .awaitingDecision)
        await parties.initiatorClock.waitForSleepers(count: 1) // session only: a person is deciding
        parties.initiatorClock.advance(by: Timeouts.nearbySession)
        #expect(await parties.initiatorEvents.first { $0.isTerminal }?.abortModel?.reason == .timeout(.session))
    }

    // MARK: - Transport events and retry

    @Test func disconnectAbortsWithoutRetry() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        _ = try await parties.handshake()
        pair.responder.close()
        let abort = await parties.initiatorEvents.first { $0.isTerminal }?.abortModel
        #expect(abort?.reason == .disconnected)
        #expect(abort?.happenedAfterReveal == true)
        let sentBefore = pair.initiator.sentFrames.count
        await #expect(throws: ShareError.nearbySessionFinished) { try await parties.initiator.start() }
        await #expect(throws: ShareError.nearbySessionFinished) { try await parties.initiator.confirmSAS() }
        #expect(pair.initiator.sentFrames.count == sentBefore)
        #expect(await parties.initiator.phase == .aborted)
    }

    @Test func secondPeerAborts() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        _ = try await parties.handshake()
        pair.responder.inject(.secondPeer)
        #expect(await parties.responderEvents.first { $0.isTerminal }?.abortModel?.reason == .secondPeer)
        #expect(await parties.initiatorEvents.first { $0.isTerminal }?.abortModel?.reason == .peerAborted(.cancelled))
    }

    @Test func dontMatchOnEitherSideTransfersNothing() async throws {
        let pair = InMemoryTransportPair()
        let parties = Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        _ = try await parties.handshake()
        try await parties.initiator.confirmSAS()
        try await parties.responder.rejectSAS()
        #expect(await parties.responderEvents.rest().last?.abortModel?.reason == .sasRejected)
        #expect(await parties.initiatorEvents.rest().last?.abortModel?.reason == .peerAborted(.sasRejected))
        let sentTypes = pair.initiator.sentFrames.compactMap { $0.count > 1 ? $0[1] : nil }
        #expect(!sentTypes.contains(NearbyMessageType.manifest.rawValue))
        await #expect(throws: ShareError.nearbySessionFinished) {
            try await parties.initiator.sendManifest(PackageFactory.sample())
        }
    }
}

/// A full man-in-the-middle with its own keys on both legs (§9.4 MITM verify item).
@Suite("Nearby MITM")
struct NearbyMITMTests {
    static func malloryMaterial(_ seed: UInt8) throws -> NearbyKeyMaterial {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        return NearbyKeyMaterial(privateKey: key, nonce: Data(repeating: seed &+ 1, count: 32))
    }

    @Test func mitmSeesDifferentCodesAndGetsNoDataWithoutConfirmations() throws {
        let kat = try NearbyKAT.load()
        // Alice ↔ Mallory (posing as Bob's Mac) and Mallory (posing as Alice's Mac) ↔ Bob.
        var aliceLeg = HandshakeHarness(
            initiator: NearbyHandshake(role: .initiator, localName: kat.inputs.nameI, keyMaterial: try kat.keyMaterial(.initiator)),
            responder: NearbyHandshake(role: .responder, localName: kat.inputs.nameR, keyMaterial: try Self.malloryMaterial(0xA0))
        )
        var bobLeg = HandshakeHarness(
            initiator: NearbyHandshake(role: .initiator, localName: kat.inputs.nameI, keyMaterial: try Self.malloryMaterial(0xB0)),
            responder: NearbyHandshake(role: .responder, localName: kat.inputs.nameR, keyMaterial: try kat.keyMaterial(.responder))
        )
        try aliceLeg.runHandshake()
        try bobLeg.runHandshake()

        let aliceCode = try #require(aliceLeg.initiator.sas?.code)
        let bobCode = try #require(bobLeg.responder.sas?.code)
        #expect(aliceCode != bobCode)
        // Names can be spoofed: only the code authenticates.
        #expect(aliceLeg.initiator.sas?.peerName == kat.inputs.nameR)

        // Mallory confirms on both legs immediately.
        aliceLeg.recordResponder(try aliceLeg.responder.confirmSAS())
        aliceLeg.pump()
        bobLeg.recordInitiator(try bobLeg.initiator.confirmSAS())
        bobLeg.pump()
        #expect(aliceLeg.initiator.phase == .comparingCodes)
        #expect(bobLeg.responder.phase == .comparingCodes)
        // Without Alice's own confirmation she cannot send anything.
        #expect(throws: ShareError.nearbyActionNotAllowed) {
            _ = try aliceLeg.initiator.sendManifest(PackageFactory.sample())
        }

        // The users see different codes and press "Don't match".
        aliceLeg.recordInitiator(try aliceLeg.initiator.rejectSAS())
        aliceLeg.pump()
        bobLeg.recordResponder(try bobLeg.responder.rejectSAS())
        bobLeg.pump()

        let manifestType = NearbyMessageType.manifest.rawValue
        #expect(!aliceLeg.initiatorFrames.contains { $0.count > 1 && $0[1] == manifestType })
        #expect(bobLeg.receivedManifest == nil)
        #expect(aliceLeg.initiatorAbort?.reason == .sasRejected)
        #expect(bobLeg.responderAbort?.reason == .sasRejected)
    }

    @Test func keySubstitutionWithoutThePrivateKeyFailsConfirm() throws {
        // A relay that swaps pkR for its own key but cannot complete the agreement.
        let mallory = try Self.malloryMaterial(0xC0)
        var harness = try HandshakeHarness.kat()
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
    }
}
