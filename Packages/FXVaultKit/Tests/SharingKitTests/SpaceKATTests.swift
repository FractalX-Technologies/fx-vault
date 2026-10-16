import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// Known-answer tests for `fxvault-space/v1` (v0.6.0) against Fixtures/space_kat.json, generated
/// by Fixtures/kat/crosscheck.py (`--write-space`) with Python's `cryptography` (HKDF, AES-GCM,
/// Ed25519, HPKE). Headers, keyrings, payloads, hashes, the marker and the fingerprint are
/// reproduced byte for byte; signatures are verified and the HPKE wraps opened.
@Suite("Shared space known-answer vectors")
struct SpaceKATTests {
    typealias Document = TeamKATTests.Document

    static func load() throws -> (Document, SpaceVersionModel, SpaceVersionModel) {
        let kat = try Document.load("space_kat.json")
        let first = try SpaceVersionModel.decode(try kat.outputBytes("wire1"))
        let second = try SpaceVersionModel.decode(try kat.outputBytes("wire2"))
        return (kat, first, second)
    }

    @Test func labelsArePinned() throws {
        let kat = try Document.load("space_kat.json")
        #expect(try kat.input("spaceLabelPrefix") == SpaceProtocol.labelPrefix)
        let python = try String(contentsOf: Fixtures.url("kat/crosscheck.py"), encoding: .utf8)
        #expect(python.contains("SPACE_PREFIX = b'fxvault/space/v1'"))
    }

    @Test func versionsDecodeToTheSameBytesAndChain() throws {
        let (kat, first, second) = try Self.load()
        let ana = try kat.device("ana")
        let ben = try kat.device("ben")
        #expect(first.headerBytes.hex == (try kat.output("header1")))
        #expect(first.keyringBytes.hex == (try kat.output("keyring1")))
        #expect(first.payloadCiphertext.hex == (try kat.output("payload1")))
        #expect(first.hash.hex == (try kat.output("hash1")))
        #expect(second.headerBytes.hex == (try kat.output("header2")))
        #expect(second.hash.hex == (try kat.output("hash2")))
        #expect(first.encoded().hex == (try kat.output("wire1")))
        #expect(second.encoded().hex == (try kat.output("wire2")))

        let spaceID = try #require(SpaceID(uuidString: try kat.input("spaceID")))
        #expect(first.header.spaceID == spaceID)
        #expect(first.header.author == ana.deviceID)
        #expect(second.header.author == ben.deviceID)
        #expect(first.header.createdAt == Date(timeIntervalSince1970: TimeInterval(try kat.number("created1")) / 1000))

        let state = try SpaceLog.verify([first, second], spaceID: spaceID)
        #expect(state.headVersion == 2)
        #expect(state.headHash.hex == (try kat.output("hash2")))
        #expect(state.members.map(\.login) == ["user-a", "user-b"])
        #expect(state.binding == SpaceBindingModel(githubRepoID: "R_repo-a", ownerLogin: "owner-a", repositoryName: "repo-a", environmentName: "production"))
    }

    @Test func wrapsOpenAndPayloadsMatch() throws {
        let (kat, first, second) = try Self.load()
        let spaceID = try #require(SpaceID(uuidString: try kat.input("spaceID")))
        let epochKey = try kat.bytes("epochKey")
        for device in [try kat.device("ana"), try kat.device("ben")] {
            let keychain = try SpaceKeychain(versions: [first, second], device: device)
            let exported = try #require(keychain.exportKey(1))
            #expect(exported.withUnsafeBytes { Data($0) } == epochKey)
            exported.wipe()
        }
        let key = SymmetricKey(data: epochKey)
        let sealed = try SpaceCrypto.sealPayload(
            try kat.outputBytes("plaintext1"),
            epochKey: key,
            spaceID: spaceID,
            header: first.headerBytes,
            keyring: first.keyringBytes,
            nonce: try AES.GCM.Nonce(data: try kat.bytes("nonce1"))
        )
        #expect(sealed.hex == (try kat.output("payload1")))
        #expect(try SpaceCrypto.openPayload(second, epochKey: key).hex == (try kat.output("plaintext2")))

        var keychain = SpaceKeychain()
        keychain.set(key, epoch: 1)
        let snapshot = try SpaceVersionBuilder.snapshot(of: second, keychain: keychain)
        defer { snapshot.wipe() }
        #expect(snapshot.reason == "rotate")
        #expect(snapshot.items.map(\.name) == ["API_KEY", "BASE_URL"])
        #expect(snapshot.items.map { $0.value?.utf8String() } == ["v2", "https://example.com"])
        #expect(SpaceSnapshotCodec.encode(snapshot).hex == (try kat.output("plaintext2")))
        let token = try #require(snapshot.items.first)
        #expect(SpaceVersionBuilder.fingerprint(token, spaceID: spaceID, keychain: keychain) == (try kat.output("fingerprint_API_KEY_v2")))
    }

    @Test func theMarkerIsCanonicalAndSigned() throws {
        let (kat, first, second) = try Self.load()
        let spaceID = try #require(SpaceID(uuidString: try kat.input("spaceID")))
        let state = try SpaceLog.verify([first, second], spaceID: spaceID)
        let text = try kat.output("marker")
        let marker = try #require(SpaceMarkerModel.decode(text))
        #expect(marker.signedMessage.hex == (try kat.output("marker_message")))
        #expect(marker.isSigned(by: state.members))
        #expect(marker.encoded() == text)
        #expect(SpaceGate.decide(markerText: text, state: state, device: try kat.device("ana").deviceID, now: .now) == .clear)
    }
}
