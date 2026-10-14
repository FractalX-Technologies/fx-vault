import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// The nearby state machine without a transport (§9.4, M6 verify list).
@Suite("Nearby handshake state machine")
struct NearbyHandshakeTests {
    // MARK: - Happy paths

    @Test func fullRunTransfersOnlyAcceptedItems() throws {
        var harness = try HandshakeHarness.kat()
        let package = PackageFactory.sample()
        try harness.runToManifest(package)

        let manifest = try #require(harness.receivedManifest)
        #expect(manifest.flattenedItems.allSatisfy { $0.item.value == nil })
        #expect(harness.responder.phase == .reviewingManifest)

        let apiKey = try #require(package.repository.secrets.first)
        let environment = try #require(package.repository.environments.first)
        let dbPassword = try #require(environment.secrets.first)
        let accepted: Set<ShareEntryID> = [apiKey.id, dbPassword.id]
        harness.recordResponder(try harness.responder.sendDecision(NearbyDecisionModel(accept: true, itemIDs: accepted)))
        harness.pump()
        #expect(harness.initiatorEvents.contains(.decisionReceived(NearbyDecisionModel(accept: true, itemIDs: accepted))))
        #expect(harness.initiator.phase == .readyForPayload)

        harness.recordInitiator(try harness.initiator.sendPayload(package))
        harness.pump()
        let payload = try #require(harness.receivedPayload)
        #expect(payload.allEntryIDs == accepted.union([environment.id]))
        #expect(payload.repository.secrets.first?.value?.utf8String() == apiKey.value?.utf8String())
        #expect(payload.repository.environments.first?.secrets.first?.value?.utf8String() == dbPassword.value?.utf8String())
        #expect(payload.repository.variables.isEmpty)

        harness.recordResponder(try harness.responder.sendResult(ok: true))
        harness.pump()
        #expect(harness.responderEvents.last == .completed(.resultSent(ok: true)))
        #expect(harness.initiatorEvents.last == .completed(.transferred(receiverOK: true)))
        #expect(harness.initiator.phase == .finished)
        #expect(harness.responder.phase == .finished)
    }

    @Test func declineEndsBothSidesWithoutPayload() throws {
        var harness = try HandshakeHarness.kat()
        try harness.runToManifest(PackageFactory.sample())
        harness.recordResponder(try harness.responder.sendDecision(.decline))
        harness.pump()
        #expect(harness.responderEvents.last == .completed(.declined))
        #expect(harness.initiatorEvents.suffix(2) == [.decisionReceived(.decline), .completed(.declined)])
        #expect(throws: ShareError.nearbySessionFinished) {
            _ = try harness.initiator.sendPayload(PackageFactory.sample())
        }
    }

    // MARK: - Confirmations gate every data frame

    @Test func manifestNeedsBothConfirmations() throws {
        var harness = try HandshakeHarness.kat()
        try harness.runHandshake()
        #expect(throws: ShareError.nearbyActionNotAllowed) {
            _ = try harness.initiator.sendManifest(PackageFactory.sample())
        }
        harness.recordInitiator(try harness.initiator.confirmSAS())
        harness.pump()
        #expect(throws: ShareError.nearbyActionNotAllowed) {
            _ = try harness.initiator.sendManifest(PackageFactory.sample())
        }
        #expect(harness.responderEvents.contains(.peerConfirmedSAS))
        #expect(harness.initiator.phase == .comparingCodes)
    }

    @Test func responderRejectsManifestBeforeItsOwnConfirmation() throws {
        var harness = try HandshakeHarness.kat()
        try harness.runHandshake()
        harness.recordInitiator(try harness.initiator.confirmSAS())
        harness.pump()
        // The responder's user has not confirmed: a (forged) MANIFEST must abort.
        var body = Data()
        body.appendBigEndian(UInt32(2))
        body.append(Data("{}".utf8))
        let forged = try KATForger().fromInitiator(.manifest, sequence: 1, body: body)
        harness.inject(toResponder: forged)
        #expect(harness.responderAbort?.reason == .unexpectedMessage)
        #expect(harness.receivedManifest == nil)
    }

    @Test func dontMatchAbortsBothSidesEncrypted() throws {
        var harness = try HandshakeHarness.kat()
        try harness.runHandshake()
        let step = try harness.responder.rejectSAS()
        let abortFrame = try #require(step.frames.first)
        #expect(abortFrame.first == NearbyProtocol.maxVersion) // encrypted, not plaintext 0x7F
        harness.recordResponder(step)
        harness.pump()
        #expect(harness.responderAbort?.reason == .sasRejected)
        #expect(harness.initiatorAbort?.reason == .peerAborted(.sasRejected))
        #expect(harness.initiatorAbort?.suggestsInterception == true)
    }

    // MARK: - Commitment, suite and version

    @Test func commitmentMismatchAbortsWithPlaintextAbort() throws {
        var harness = try HandshakeHarness.kat()
        harness.interceptToResponder = { frame in
            guard frame.first == NearbyMessageType.revealInitiator.rawValue else { return [frame] }
            var tampered = frame
            tampered[tampered.count - 1] ^= 0x01 // flip a bit of nI
            return [tampered]
        }
        try harness.runHandshake()
        #expect(harness.responderAbort?.reason == .commitmentMismatch)
        #expect(harness.responderAbort?.suggestsInterception == true)
        #expect(harness.responderFrames.last?.first == NearbyMessageType.abort.rawValue)
        #expect(harness.initiatorAbort?.reason == .peerAborted(.commitmentMismatch))
        #expect(harness.responder.sas == nil)
    }

    @Test func unsupportedSuiteFromInitiatorAborts() throws {
        var responder = NearbyHandshake(role: .responder, localName: "R")
        _ = try responder.start()
        let hello = NearbyHandshakeFrame.helloInitiator(maxVersion: 1, suite: 2, commitment: Data(count: 32), name: Data("I".utf8))
        let step = responder.receive(hello.encoded())
        #expect(step.abortReason == .unsupportedSuite)
        #expect(step.frames == [NearbyHandshakeFrame.abort(code: NearbyAbortCode.unsupportedSuite.rawValue).encoded()])
    }

    @Test func suiteMismatchFromResponderAborts() throws {
        var harness = try HandshakeHarness.kat()
        harness.interceptToInitiator = { frame in
            guard frame.first == NearbyMessageType.helloResponder.rawValue else { return [frame] }
            var tampered = frame
            tampered[2] = 0x02 // suiteR
            return [tampered]
        }
        try harness.runHandshake()
        #expect(harness.initiatorAbort?.reason == .suiteMismatch)
        #expect(harness.initiator.sas == nil)
    }

    @Test func versionZeroIsRejectedOnBothSides() throws {
        var responder = NearbyHandshake(role: .responder, localName: "R")
        _ = try responder.start()
        let helloI = NearbyHandshakeFrame.helloInitiator(maxVersion: 0, suite: 1, commitment: Data(count: 32), name: Data())
        #expect(responder.receive(helloI.encoded()).abortReason == .unsupportedVersion)

        var harness = try HandshakeHarness.kat()
        harness.interceptToInitiator = { frame in
            guard frame.first == NearbyMessageType.helloResponder.rawValue else { return [frame] }
            var tampered = frame
            tampered[1] = 0x00 // maxVerR
            return [tampered]
        }
        try harness.runHandshake()
        #expect(harness.initiatorAbort?.reason == .unsupportedVersion)
    }

    @Test func downgradeOfInitiatorVersionBreaksTheCommitment() throws {
        var harness = try HandshakeHarness.kat()
        harness.interceptToResponder = { frame in
            guard frame.first == NearbyMessageType.helloInitiator.rawValue else { return [frame] }
            var tampered = frame
            tampered[1] = 0x02 // maxVerI rewritten by a relay
            return [tampered]
        }
        try harness.runHandshake()
        #expect(harness.responderAbort?.reason == .commitmentMismatch)
    }

    @Test func tamperedResponderVersionChangesTheSASAndBreaksConfirm() throws {
        var harness = try HandshakeHarness.kat()
        harness.interceptToInitiator = { frame in
            guard frame.first == NearbyMessageType.helloResponder.rawValue else { return [frame] }
            var tampered = frame
            tampered[1] = 0x02 // maxVerR: the negotiated version stays 1, but TH differs
            return [tampered]
        }
        try harness.runHandshake()
        let initiatorCode = try #require(harness.initiator.sas?.code)
        let responderCode = try #require(harness.responder.sas?.code)
        #expect(initiatorCode != responderCode)
        harness.recordInitiator(try harness.initiator.confirmSAS())
        harness.pump()
        #expect(harness.responderAbort?.reason == .decryptionFailed)
    }

    // MARK: - Keys

    static let lowOrderPoints: [String] = [
        String(repeating: "00", count: 32),
        "01" + String(repeating: "00", count: 31),
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
        "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    ]

    @Test(arguments: lowOrderPoints)
    func lowOrderResponderKeyAborts(_ pointHex: String) throws {
        let point = try #require(Data(hex: pointHex))
        var harness = try HandshakeHarness.kat()
        harness.interceptToInitiator = { frame in
            guard frame.first == NearbyMessageType.helloResponder.rawValue else { return [frame] }
            var tampered = frame
            tampered.replaceSubrange(3..<35, with: point)
            return [tampered]
        }
        try harness.runHandshake()
        #expect(harness.initiatorAbort?.reason == .invalidKey)
        #expect(harness.initiator.sas == nil)
    }

    @Test(arguments: lowOrderPoints)
    func lowOrderInitiatorKeyAborts(_ pointHex: String) throws {
        let point = try #require(Data(hex: pointHex))
        let nonce = Data(repeating: 0x55, count: 32)
        var responder = NearbyHandshake(role: .responder, localName: "R")
        _ = try responder.start()
        // A malicious initiator commits honestly to a low-order key.
        let commitment = NearbyCrypto.commitment(maxVersion: 1, suite: 1, publicKey: point, nonce: nonce)
        let hello = NearbyHandshakeFrame.helloInitiator(maxVersion: 1, suite: 1, commitment: commitment, name: Data())
        #expect(responder.receive(hello.encoded()).abortReason == nil)
        let reveal = NearbyHandshakeFrame.revealInitiator(publicKey: point, nonce: nonce)
        #expect(responder.receive(reveal.encoded()).abortReason == .invalidKey)
        #expect(responder.sas == nil)
    }

    // MARK: - Sequence, replay, reorder, truncation, direction

    @Test func replayedFrameIsRejected() throws {
        var harness = try HandshakeHarness.kat()
        try harness.runToReadyForManifest()
        let confirm = try #require(harness.initiatorFrames.last)
        harness.inject(toResponder: confirm)
        #expect(harness.responderAbort?.reason == .sequenceMismatch)
    }

    @Test func reorderedFramesAreRejected() throws {
        var harness = try HandshakeHarness.kat()
        var held: [Data] = []
        harness.interceptToResponder = { frame in
            // Hold the encrypted CONFIRM (seq 0) and deliver the next frame first.
            if frame.first == NearbyProtocol.maxVersion, frame[1] == NearbyMessageType.confirm.rawValue {
                held.append(frame)
                return []
            }
            return [frame]
        }
        try harness.runHandshake()
        harness.recordInitiator(try harness.initiator.confirmSAS())
        harness.pump()
        #expect(held.count == 1)
        // seq 1 before seq 0.
        let forged = try KATForger().fromInitiator(.close, sequence: 1, body: Data())
        harness.inject(toResponder: forged)
        #expect(harness.responderAbort?.reason == .sequenceMismatch)
    }

    @Test func truncatedFramesAreRejected() throws {
        // Encrypted frame missing its last tag byte.
        var harness = try HandshakeHarness.kat()
        try harness.runHandshake()
        let confirm = try harness.initiator.confirmSAS()
        let frame = try #require(confirm.frames.first)
        harness.inject(toResponder: frame.dropLast())
        #expect(harness.responderAbort?.reason == .decryptionFailed)

        // Shorter than header plus tag.
        var second = try HandshakeHarness.kat()
        try second.runHandshake()
        second.inject(toResponder: Data([0x01, 0x10, 0, 0, 0]))
        #expect(second.responderAbort?.reason == .malformedFrame)

        // Truncated HELLO_I.
        var responder = NearbyHandshake(role: .responder, localName: "R")
        _ = try responder.start()
        var initiator = NearbyHandshake(role: .initiator, localName: "I")
        let hello = try #require(try initiator.start().frames.first)
        #expect(responder.receive(hello.prefix(20)).abortReason == .malformedFrame)
    }

    @Test func reflectedFrameFailsAuthentication() throws {
        var harness = try HandshakeHarness.kat()
        try harness.runHandshake()
        let confirm = try harness.initiator.confirmSAS()
        let frame = try #require(confirm.frames.first)
        // Sent back to its own author: opened with the r2i key, so GCM fails.
        harness.inject(toInitiator: frame)
        #expect(harness.initiatorAbort?.reason == .decryptionFailed)
    }

    @Test func tamperedEncryptedHeaderFailsAuthentication() throws {
        var harness = try HandshakeHarness.kat()
        try harness.runHandshake()
        var frame = try #require(try harness.initiator.confirmSAS().frames.first)
        frame[1] = NearbyMessageType.manifest.rawValue // type is in the AAD
        harness.inject(toResponder: frame)
        #expect(harness.responderAbort?.reason == .decryptionFailed)
    }

    @Test func unexpectedMessagesAbort() throws {
        // REVEAL before HELLO_I.
        var responder = NearbyHandshake(role: .responder, localName: "R")
        _ = try responder.start()
        let reveal = NearbyHandshakeFrame.revealInitiator(publicKey: Data(count: 32), nonce: Data(count: 32))
        #expect(responder.receive(reveal.encoded()).abortReason == .unexpectedMessage)

        // An initiator receiving HELLO_I.
        var initiator = NearbyHandshake(role: .initiator, localName: "I")
        let hello = try #require(try initiator.start().frames.first)
        #expect(initiator.receive(hello).abortReason == .unexpectedMessage)

        // A frame before start().
        var idle = NearbyHandshake(role: .responder, localName: "R")
        #expect(idle.receive(hello).abortReason == .unexpectedMessage)

        // An unknown type byte.
        var other = NearbyHandshake(role: .responder, localName: "R")
        _ = try other.start()
        #expect(other.receive(Data([0x42, 0x00])).abortReason == .unexpectedMessage)
    }

    // MARK: - Sizes

    @Test func oversizeFramesAbort() throws {
        var responder = NearbyHandshake(role: .responder, localName: "R")
        _ = try responder.start()
        let oversizeHandshake = Data([NearbyMessageType.helloInitiator.rawValue])
            + Data(count: Limits.maxNearbyHandshakeFrameBytes)
        #expect(responder.receive(oversizeHandshake).abortReason == .oversizeFrame)

        var harness = try HandshakeHarness.kat()
        try harness.runHandshake()
        let oversizeEncrypted = Data([NearbyProtocol.maxVersion, NearbyMessageType.confirm.rawValue])
            + Data(count: Limits.maxNearbyEncryptedFrameBytes)
        harness.inject(toResponder: oversizeEncrypted)
        #expect(harness.responderAbort?.reason == .oversizeFrame)
    }

    @Test func helloNameLongerThanTheLimitIsMalformed() throws {
        var responder = NearbyHandshake(role: .responder, localName: "R")
        _ = try responder.start()
        let name = Data(repeating: 0x41, count: Limits.maxDisplayNameBytes + 1)
        let hello = NearbyHandshakeFrame.helloInitiator(maxVersion: 1, suite: 1, commitment: Data(count: 32), name: name)
        #expect(responder.receive(hello.encoded()).abortReason == .malformedFrame)
    }

    @Test func localNameIsSanitizedBeforeSending() throws {
        var initiator = NearbyHandshake(role: .initiator, localName: "  Evil\u{202E}Mac\u{200B} ")
        let hello = try #require(try initiator.start().frames.first)
        guard case .helloInitiator(_, _, _, let name) = try NearbyHandshakeFrame.decode(hello) else {
            Issue.record("Expected HELLO_I")
            return
        }
        #expect(String(decoding: name, as: UTF8.self) == "EvilMac")
    }

    // MARK: - DECISION and PAYLOAD integrity

    @Test func decisionWithUnknownIDsAborts() throws {
        var harness = try HandshakeHarness.kat()
        try harness.runToManifest(PackageFactory.sample())
        // The responder API refuses ids that are not in the manifest...
        #expect(throws: ShareError.nearbyActionNotAllowed) {
            _ = try harness.responder.sendDecision(NearbyDecisionModel(accept: true, itemIDs: [ShareEntryID()]))
        }
        // ...and the initiator aborts on a forged DECISION that lists one.
        let decision = NearbyMessageBody.decision(NearbyDecisionModel(accept: true, itemIDs: [ShareEntryID()]))
        let forged = try KATForger().fromResponder(.decision, sequence: 1, body: decision)
        harness.inject(toInitiator: forged)
        #expect(harness.initiatorAbort?.reason == .unknownItemIDs)
        #expect(harness.initiatorFrames.allSatisfy { $0.count < 2 || $0[1] != NearbyMessageType.payloadChunk.rawValue })
    }

    @Test func payloadEndMismatchAborts() throws {
        var harness = try HandshakeHarness.kat()
        let package = PackageFactory.sample()
        try harness.runToManifest(package)
        let id = try #require(package.repository.secrets.first?.id)
        harness.recordResponder(try harness.responder.sendDecision(NearbyDecisionModel(accept: true, itemIDs: [id])))
        harness.pump()
        let forger = try KATForger()
        let sequence = harness.initiatorEncryptedCount
        harness.inject(toResponder: try forger.fromInitiator(.payloadChunk, sequence: sequence, body: Data("{}".utf8)))
        let end = NearbyMessageBody.payloadEnd(length: 2, digest: Data(count: 32))
        harness.inject(toResponder: try forger.fromInitiator(.payloadEnd, sequence: sequence + 1, body: end))
        #expect(harness.responderAbort?.reason == .payloadMismatch)
        #expect(harness.receivedPayload == nil)
    }

    @Test func payloadWithUnacceptedItemsAborts() throws {
        var harness = try HandshakeHarness.kat()
        let package = PackageFactory.sample()
        try harness.runToManifest(package)
        let id = try #require(package.repository.secrets.first?.id)
        harness.recordResponder(try harness.responder.sendDecision(NearbyDecisionModel(accept: true, itemIDs: [id])))
        harness.pump()
        // A malicious sender pushes the whole package instead of the accepted item.
        let json = try SharePackageCoder.encode(package)
        let bytes = json.withUnsafeBytes { Data($0) }
        let forger = try KATForger()
        let sequence = harness.initiatorEncryptedCount
        harness.inject(toResponder: try forger.fromInitiator(.payloadChunk, sequence: sequence, body: bytes))
        let end = NearbyMessageBody.payloadEnd(length: UInt64(bytes.count), digest: Data(SHA256.hash(data: bytes)))
        harness.inject(toResponder: try forger.fromInitiator(.payloadEnd, sequence: sequence + 1, body: end))
        #expect(harness.responderAbort?.reason == .payloadMismatch)
        #expect(harness.receivedPayload == nil)
    }

    @Test func sendPayloadRefusesAPackageThatDoesNotMatchTheManifest() throws {
        var harness = try HandshakeHarness.kat()
        let package = PackageFactory.sample()
        try harness.runToManifest(package)
        let id = try #require(package.repository.secrets.first?.id)
        harness.recordResponder(try harness.responder.sendDecision(NearbyDecisionModel(accept: true, itemIDs: [id])))
        harness.pump()
        var renamed = package
        renamed.repository.secrets[0].name = "OTHER_NAME"
        #expect(throws: ShareError.nearbyActionNotAllowed) {
            _ = try harness.initiator.sendPayload(renamed)
        }
        #expect(harness.initiator.phase == .readyForPayload)
    }

    @Test func largeManifestAndPayloadSpanSeveralFrames() throws {
        var harness = try HandshakeHarness.kat()
        let bigValue = String(repeating: "x", count: Limits.maxValueBytes)
        let variables = (0..<40).map { PackageFactory.item("VARIABLE_\($0)_" + String(repeating: "N", count: 200), value: bigValue) }
        let package = PackageFactory.package(variables: variables)
        try harness.runToManifest(package)
        let manifestFrames = harness.initiatorFrames.filter { $0.count > 1 && $0[1] == NearbyMessageType.manifest.rawValue }
        #expect(manifestFrames.count >= 1)
        let manifest = try #require(harness.receivedManifest)
        #expect(manifest.itemCount == 40)

        harness.recordResponder(try harness.responder.sendDecision(NearbyDecisionModel(accept: true, itemIDs: manifest.allEntryIDs)))
        harness.pump()
        harness.recordInitiator(try harness.initiator.sendPayload(package))
        harness.pump()
        let chunks = harness.initiatorFrames.filter { $0.count > 1 && $0[1] == NearbyMessageType.payloadChunk.rawValue }
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= Limits.maxNearbyEncryptedFrameBytes })
        let payload = try #require(harness.receivedPayload)
        #expect(payload.repository.variables.map { $0.value?.utf8String() } == variables.map { $0.value?.utf8String() })
    }

    // MARK: - No resume, no retry

    @Test func abortIsFinal() throws {
        var harness = try HandshakeHarness.kat()
        try harness.runHandshake()
        let step = harness.initiator.abort(.cancelled)
        #expect(step.frames.count == 1)
        #expect(step.abortReason == .cancelled)
        #expect(harness.initiator.phase == .aborted)

        #expect(throws: ShareError.nearbySessionFinished) { _ = try harness.initiator.start() }
        #expect(throws: ShareError.nearbySessionFinished) { _ = try harness.initiator.confirmSAS() }
        #expect(throws: ShareError.nearbySessionFinished) { _ = try harness.initiator.sendManifest(PackageFactory.sample()) }
        #expect(harness.initiator.abort(.cancelled) == NearbyStep())
        let late = try #require(harness.responderFrames.first)
        #expect(harness.initiator.receive(late) == NearbyStep())
    }

    @Test func startTwiceIsRejected() throws {
        var initiator = NearbyHandshake(role: .initiator, localName: "I")
        _ = try initiator.start()
        #expect(throws: ShareError.nearbyActionNotAllowed) { _ = try initiator.start() }
    }

    @Test func freshMaterialGivesDifferentCodesPerSession() throws {
        var first = HandshakeHarness(
            initiator: NearbyHandshake(role: .initiator, localName: "I"),
            responder: NearbyHandshake(role: .responder, localName: "R")
        )
        var second = HandshakeHarness(
            initiator: NearbyHandshake(role: .initiator, localName: "I"),
            responder: NearbyHandshake(role: .responder, localName: "R")
        )
        try first.runHandshake()
        try second.runHandshake()
        #expect(first.initiator.sas?.code == first.responder.sas?.code)
        #expect(first.initiatorFrames.first != second.initiatorFrames.first)
    }
}

@Suite("Nearby interception warning")
struct NearbyFailureTrackerTests {
    @Test func warnsAfterRevealOrTwoFailures() {
        var tracker = NearbyFailureTracker()
        #expect(tracker.record(NearbyAbortModel(reason: .timeout(.handshake), happenedAfterReveal: false)) == false)
        #expect(tracker.record(NearbyAbortModel(reason: .disconnected, happenedAfterReveal: false)) == true)
        tracker.recordSuccess()
        #expect(tracker.record(NearbyAbortModel(reason: .decryptionFailed, happenedAfterReveal: true)) == true)
        tracker.recordSuccess()
        #expect(tracker.record(NearbyAbortModel(reason: .cancelled, happenedAfterReveal: true)) == false)
        #expect(tracker.consecutiveFailures == 0)
    }

    @Test func abortModelClassification() {
        #expect(NearbyAbortModel(reason: .commitmentMismatch, happenedAfterReveal: false).suggestsInterception)
        #expect(NearbyAbortModel(reason: .sasRejected, happenedAfterReveal: true).suggestsInterception)
        #expect(!NearbyAbortModel(reason: .timeout(.sas), happenedAfterReveal: true).suggestsInterception)
        #expect(!NearbyAbortModel(reason: .peerAborted(.cancelled), happenedAfterReveal: true).suggestsInterception)
        #expect(NearbyAbortModel(reason: .peerAborted(.sasRejected), happenedAfterReveal: true).suggestsInterception)
    }
}
