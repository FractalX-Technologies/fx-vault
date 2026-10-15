import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// Known-answer tests for `fxvault-chat/v1` against Fixtures/chat_kat.json. The vectors come
/// from Fixtures/kat/crosscheck.py (`--write-chat`) and match
/// Fixtures/kat/NearbyProtocolReference.swift byte for byte (its `chat_` lines).
@Suite("Nearby chat known-answer vectors")
struct NearbyChatKATTests {
    @Test func labelsAreDomainSeparated() throws {
        let kat = try ChatKAT.load()
        #expect(kat.inputs.labelPrefix == NearbyChatProtocol.labelPrefix)
        #expect(NearbyLabels.chat.commit == Data("fxvault/chat/v1/commit".utf8))
        #expect(NearbyLabels.chat.transcript == Data("fxvault/chat/v1/transcript".utf8))
        #expect(NearbyLabels.chat.sas == Data("fxvault/chat/v1/sas".utf8))
        #expect(NearbyLabels.chat.initiatorToResponder == Data("fxvault/chat/v1/key/i2r".utf8))
        #expect(NearbyLabels.chat.responderToInitiator == Data("fxvault/chat/v1/key/r2i".utf8))
        // The share labels are unchanged since 0.1.0.
        #expect(NearbyLabels.share.commit == Data("fxvault/nearby/v1/commit".utf8))
        #expect(NearbyLabels.share.responderToInitiator == Data("fxvault/nearby/v1/key/r2i".utf8))
        #expect(NearbyPurpose.share.labels == .share)
        #expect(NearbyPurpose.chat.labels == .chat)
        #expect(NearbyPurpose.share.bonjourServiceType == "_fxvault-share._tcp")
        #expect(NearbyPurpose.chat.bonjourServiceType == "_fxvault-chat._tcp")
    }

    @Test func generatorsAreBundled() throws {
        let python = try String(contentsOf: Fixtures.url("kat/crosscheck.py"), encoding: .utf8)
        let swift = try String(contentsOf: Fixtures.url("kat/NearbyProtocolReference.swift"), encoding: .utf8)
        #expect(python.contains("CHAT_PREFIX = b'fxvault/chat/v1'"))
        #expect(swift.contains("Labels(prefix: \"fxvault/chat/v1\")"))
    }

    @Test func commitmentTranscriptSASAndKeys() throws {
        let kat = try ChatKAT.load()
        let share = try NearbyKAT.load()
        let initiator = try kat.keyMaterial(.initiator)
        let responder = try kat.keyMaterial(.responder)
        #expect(initiator.publicKey.hex == (try kat.output("pkI")))
        #expect(responder.publicKey.hex == (try kat.output("pkR")))

        let commitment = NearbyCrypto.commitment(
            maxVersion: 1,
            suite: 1,
            publicKey: initiator.publicKey,
            nonce: initiator.nonce,
            labels: .chat
        )
        #expect(commitment.hex == (try kat.output("C")))
        #expect(commitment.hex != (try share.output("C")))

        let secret = try NearbyCrypto.sharedSecret(privateKey: initiator.privateKey, peerPublicKey: responder.publicKey)
        #expect(secret.withUnsafeBytes { Data($0) }.hex == (try kat.output("shared_secret")))
        let transcript = Self.transcript(kat: kat, commitment: commitment, initiator: initiator, responder: responder)
        let th = NearbyCrypto.transcriptHash(transcript, labels: .chat)
        #expect(th.hex == (try kat.output("TH")))
        #expect(th.hex != (try share.output("TH")))

        let keys = NearbyCrypto.deriveSession(sharedSecret: secret, transcriptHash: th, labels: .chat)
        #expect(NearbySASModel(value: keys.sasValue, peerName: "").code == (try kat.output("SAS")))
        #expect(String(keys.sasValue) == (try kat.output("SAS_value")))
        #expect(keys.initiatorToResponder.withUnsafeBytes { Data($0) }.hex == (try kat.output("k_i2r")))
        #expect(keys.responderToInitiator.withUnsafeBytes { Data($0) }.hex == (try kat.output("k_r2i")))
        #expect(keys.initiatorToResponder.withUnsafeBytes { Data($0) }.hex != (try share.output("k_i2r")))

        // A share commitment run through the chat transcript gives yet another code.
        let shareCommitment = NearbyCrypto.commitment(
            maxVersion: 1,
            suite: 1,
            publicKey: initiator.publicKey,
            nonce: initiator.nonce
        )
        let mixed = Self.transcript(kat: kat, commitment: shareCommitment, initiator: initiator, responder: responder)
        let mixedKeys = NearbyCrypto.deriveSession(
            sharedSecret: secret,
            transcriptHash: NearbyCrypto.transcriptHash(mixed, labels: .chat),
            labels: .chat
        )
        #expect(NearbySASModel(value: mixedKeys.sasValue, peerName: "").code == (try kat.output("SAS_with_share_commitment")))
    }

    @Test func stateMachineReproducesTheVectors() throws {
        let kat = try ChatKAT.load()
        var harness = try ChatHarness.kat()
        try harness.runHandshake()

        let expectedSAS = try kat.output("SAS")
        #expect(harness.initiator.sas?.code == expectedSAS)
        #expect(harness.responder.sas?.code == expectedSAS)
        // HELLO_I carries the chat commitment right after type, maxVer and suite.
        let helloI = try #require(harness.initiatorFrames.first)
        #expect(helloI.bytes(at: 3, length: 32)?.hex == (try kat.output("C")))

        let initiatorConfirm = try harness.initiator.confirmSAS()
        #expect(initiatorConfirm.frames.map(\.hex) == [try kat.output("CONFIRM_i2r_seq0")])
        harness.recordInitiator(initiatorConfirm)
        let responderConfirm = try harness.responder.confirmSAS()
        #expect(responderConfirm.frames.map(\.hex) == [try kat.output("CONFIRM_r2i_seq0")])
        harness.recordResponder(responderConfirm)
        harness.pump()
        #expect(harness.initiator.phase == .chatting)
        #expect(harness.responder.phase == .chatting)

        let (text, _) = try harness.initiator.sendText(kat.inputs.text_utf8, at: ChatHarness.date)
        #expect(text.frames.map(\.hex) == [try kat.output("TEXT_i2r_seq1")])
        let ping = harness.responder.keepaliveTick()
        #expect(ping.frames.map(\.hex) == [try kat.output("PING_r2i_seq1")])
        let close = harness.initiator.close()
        #expect(close.frames.map(\.hex) == [try kat.output("CLOSE_i2r_seq2")])
    }

    static func transcript(
        kat: ChatKAT,
        commitment: Data,
        initiator: NearbyKeyMaterial,
        responder: NearbyKeyMaterial
    ) -> NearbyTranscriptModel {
        NearbyTranscriptModel(
            maxVersionI: 1,
            maxVersionR: 1,
            version: 1,
            suiteI: 1,
            suiteR: 1,
            commitment: commitment,
            publicKeyI: initiator.publicKey,
            nonceI: initiator.nonce,
            nameI: Data(kat.inputs.nameI.utf8),
            publicKeyR: responder.publicKey,
            nonceR: responder.nonce,
            nameR: Data(kat.inputs.nameR.utf8)
        )
    }
}
