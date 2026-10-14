import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// Known-answer tests against Fixtures/nearby_kat.json (§9.4 KATs). The vectors were produced
/// by Fixtures/kat/crosscheck.py and match Fixtures/kat/NearbyProtocolReference.swift
/// byte for byte.
@Suite("Nearby known-answer vectors")
struct NearbyKATTests {
    @Test func referenceGeneratorsAreBundled() throws {
        let python = try String(contentsOf: Fixtures.url("kat/crosscheck.py"), encoding: .utf8)
        let swift = try String(contentsOf: Fixtures.url("kat/NearbyProtocolReference.swift"), encoding: .utf8)
        #expect(python.contains("suite_i, suite_r"))
        #expect(swift.contains("t.suiteI, t.suiteR"))
    }

    @Test func publicKeysCommitmentAndTranscript() throws {
        let kat = try NearbyKAT.load()
        let initiator = try kat.keyMaterial(.initiator)
        let responder = try kat.keyMaterial(.responder)
        #expect(initiator.publicKey.hex == (try kat.output("pkI")))
        #expect(responder.publicKey.hex == (try kat.output("pkR")))

        let commitment = NearbyCrypto.commitment(
            maxVersion: 1,
            suite: 1,
            publicKey: initiator.publicKey,
            nonce: initiator.nonce
        )
        #expect(commitment.hex == (try kat.output("C")))

        let transcript = Self.transcript(kat: kat, commitment: commitment, initiator: initiator, responder: responder)
        #expect(NearbyCrypto.transcriptHash(transcript).hex == (try kat.output("TH")))

        var higherResponder = transcript
        higherResponder.maxVersionR = 2
        #expect(NearbyCrypto.transcriptHash(higherResponder).hex == (try kat.output("TH_maxVerR_2")))
    }

    @Test func sasAndDirectionKeys() throws {
        let kat = try NearbyKAT.load()
        let initiator = try kat.keyMaterial(.initiator)
        let responder = try kat.keyMaterial(.responder)
        let secret = try NearbyCrypto.sharedSecret(privateKey: initiator.privateKey, peerPublicKey: responder.publicKey)
        #expect(secret.withUnsafeBytes { Data($0) }.hex == (try kat.output("shared_secret")))

        let commitment = NearbyCrypto.commitment(maxVersion: 1, suite: 1, publicKey: initiator.publicKey, nonce: initiator.nonce)
        let transcript = Self.transcript(kat: kat, commitment: commitment, initiator: initiator, responder: responder)
        let keys = NearbyCrypto.deriveSession(sharedSecret: secret, transcriptHash: NearbyCrypto.transcriptHash(transcript))
        let sas = NearbySASModel(value: keys.sasValue, peerName: "")
        #expect(sas.code == (try kat.output("SAS")))
        #expect(String(keys.sasValue) == (try kat.output("SAS_value")))
        #expect(keys.initiatorToResponder.withUnsafeBytes { Data($0) }.hex == (try kat.output("k_i2r")))
        #expect(keys.responderToInitiator.withUnsafeBytes { Data($0) }.hex == (try kat.output("k_r2i")))

        var altered = transcript
        altered.nameR = Data(kat.inputs.nameR_altered.utf8)
        let alteredKeys = NearbyCrypto.deriveSession(sharedSecret: secret, transcriptHash: NearbyCrypto.transcriptHash(altered))
        let alteredSAS = NearbySASModel(value: alteredKeys.sasValue, peerName: "").code
        #expect(alteredSAS == (try kat.output("SAS_altered_nameR")))
        #expect(alteredSAS != sas.code)
    }

    @Test func stateMachineReproducesTheVectors() throws {
        let kat = try NearbyKAT.load()
        var harness = try HandshakeHarness.kat()
        try harness.runHandshake()

        let expectedSAS = try kat.output("SAS")
        #expect(harness.initiator.sas?.code == expectedSAS)
        #expect(harness.responder.sas?.code == expectedSAS)
        #expect(harness.initiator.sas?.peerName == kat.inputs.nameR)
        #expect(harness.responder.sas?.peerName == kat.inputs.nameI)

        // HELLO_I carries C right after type, maxVer and suite.
        let helloI = try #require(harness.initiatorFrames.first)
        #expect(helloI.bytes(at: 3, length: 32)?.hex == (try kat.output("C")))

        let initiatorConfirm = try harness.initiator.confirmSAS()
        #expect(initiatorConfirm.frames.map(\.hex) == [try kat.output("CONFIRM_i2r_seq0")])
        let responderConfirm = try harness.responder.confirmSAS()
        #expect(responderConfirm.frames.map(\.hex) == [try kat.output("CONFIRM_r2i_seq0")])
    }

    @Test func sasFormattingPadsAndGroups() {
        #expect(NearbySASModel(value: 0, peerName: "").code == "000 000")
        #expect(NearbySASModel(value: 7, peerName: "").code == "000 007")
        #expect(NearbySASModel(value: 42_195, peerName: "").code == "042 195")
        #expect(NearbySASModel(value: 999_999, peerName: "").code == "999 999")
    }

    static func transcript(
        kat: NearbyKAT,
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
