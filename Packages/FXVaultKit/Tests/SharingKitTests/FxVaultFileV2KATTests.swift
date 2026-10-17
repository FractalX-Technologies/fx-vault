import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// Known-answer tests for `.fxvault` format 2 (v0.9.0) against Fixtures/file_v2_kat.json, made by
/// Fixtures/kat/file_v2_kat.py. Passphrase mode is reproduced byte for byte. The teammates file
/// uses fixed HPKE ephemerals and deterministic Ed25519 in Python, which CryptoKit cannot repeat,
/// so Swift opens it and reproduces its header, slot ids, signed message and ciphertext.
@Suite("fxvault format 2 known-answer vectors")
struct FxVaultFileV2KATTests {
    typealias Document = TeamKATTests.Document

    static func load() throws -> Document {
        try Document.load("file_v2_kat.json")
    }

    static let passphrase = SecretBytes(utf8: "abacus-abdomen-abdominal-abide-abiding-ability")

    @Test func labelsArePinned() throws {
        let kat = try Self.load()
        let labels = [FxVaultTeammateCrypto.slotLabel, FxVaultTeammateCrypto.wrapLabel, FxVaultTeammateCrypto.signLabel]
            .compactMap { String(data: $0, encoding: .utf8) }
        #expect(try kat.input("labels") == labels.joined(separator: " "))
        let python = try String(contentsOf: Fixtures.url("kat/file_v2_kat.py"), encoding: .utf8)
        for label in labels {
            #expect(python.contains("b'\(label)'"))
        }
    }

    // MARK: - Passphrase mode

    @Test func passphraseModeIsReproducedByteForByte() async throws {
        let kat = try Self.load()
        let header = try FxVaultHeaderV2Model(
            passphraseOpsLimit: UInt32(try kat.number("passphraseOpsLimit")),
            memLimitKiB: UInt32(try kat.number("passphraseMemLimitKiB")),
            salt: Array(try kat.bytes("passphraseSalt")),
            nonce: Array(try kat.bytes("passphraseNonce"))
        )
        #expect(header.encoded().hex == (try kat.output("passphrase_header")))
        let file = try kat.outputBytes("passphrase_file")
        #expect(try FxVaultHeaderV2Model.parse(file) == header)
        #expect(try FxVaultFileV2Codec.inspect(file) == .v2Passphrase(header))

        let payload = Data(try kat.input("passphrasePayloadUTF8").utf8)
        let codec = FxVaultFileV2Codec(deriver: FixedKeyDeriver(key: try kat.bytes("passphraseKey")))
        let sealed = try await codec.sealWithPassphrase(payload: SecretBytes(payload), passphrase: Self.passphrase, header: header)
        #expect(sealed == file)
        let opened = try await codec.openWithPassphrase(file, passphrase: Self.passphrase)
        #expect(opened.withUnsafeBytes { Data($0) } == payload)
    }

    // MARK: - Teammates mode

    @Test func teammatesFileOpensForEachRecipient() throws {
        let kat = try Self.load()
        let file = try kat.outputBytes("teammates_file")
        let sender = try kat.device("sender")
        let payload = Data(try kat.input("teammatesPayloadUTF8").utf8)
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        for name in ["ana", "ben"] {
            let opened = try codec.openAsTeammate(file, device: try kat.device(name), teammates: [ShareTeammateKeyModel(device: sender)])
            #expect(opened.payload.withUnsafeBytes { Data($0) } == payload)
            #expect(opened.sender.hex == (try kat.output("sender_device_id")))
            #expect(opened.senderAnnounceKey == (try kat.bytes("senderAnnounceKey")))
            opened.payload.wipe()
        }
        #expect(throws: ShareError.notARecipient) {
            _ = try codec.openAsTeammate(file, device: sender, teammates: [ShareTeammateKeyModel(device: sender)])
        }
    }

    @Test func teammatesFramingIsReproduced() throws {
        let kat = try Self.load()
        let file = try kat.outputBytes("teammates_file")
        let salt = Array(try kat.bytes("teammatesSalt"))
        let nonce = Array(try kat.bytes("teammatesNonce"))
        let header = try FxVaultHeaderV2Model(teammatesRecipientCount: 2, salt: salt, nonce: nonce)
        let headerBytes = header.encoded()
        #expect(headerBytes.hex == (try kat.output("teammates_header")))
        #expect(try FxVaultFileV2Codec.inspect(file) == .v2Teammates(header, recipientCount: 2))

        let sender = try kat.device("sender")
        let ana = try kat.device("ana")
        let ben = try kat.device("ben")
        #expect(sender.deviceID.hex == (try kat.output("sender_device_id")))
        #expect(ana.deviceID.hex == (try kat.output("ana_device_id")))
        #expect(ben.deviceID.hex == (try kat.output("ben_device_id")))
        #expect(FxVaultTeammateCrypto.slotID(salt: salt, deviceID: ana.deviceID).hex == (try kat.output("ana_slot_id")))
        #expect(FxVaultTeammateCrypto.slotID(salt: salt, deviceID: ben.deviceID).hex == (try kat.output("ben_slot_id")))

        let slotBytes = try kat.outputBytes("teammates_slots")
        #expect(file.bytes(at: Limits.shareHeaderBytes, length: slotBytes.count) == slotBytes)
        let slots = try FxVaultRecipientSlot.parseAll(file, at: Limits.shareHeaderBytes, count: 2)
        #expect(slots.map { $0.encoded() }.reduce(Data(), +) == slotBytes)
        let contentKey = SymmetricKey(data: try kat.bytes("teammatesContentKey"))
        let anaSlotID = FxVaultTeammateCrypto.slotID(salt: salt, deviceID: ana.deviceID)
        let anaSlot = try #require(slots.first { $0.slotID == anaSlotID })
        let unwrapped = try #require(FxVaultTeammateCrypto.unwrap(anaSlot, header: headerBytes, agreement: ana.agreement))
        #expect(unwrapped == contentKey)

        let payload = Data(try kat.input("teammatesPayloadUTF8").utf8)
        let message = FxVaultTeammateCrypto.signedMessage(
            header: headerBytes,
            slots: slotBytes,
            sender: sender.deviceID,
            announceKey: try kat.bytes("senderAnnounceKey"),
            payloadDigest: Data(SHA256.hash(data: payload))
        )
        #expect(message.hex == (try kat.output("teammates_signed_message")))
        let signature = try kat.outputBytes("teammates_signature")
        #expect(ShareTeammateKeyModel(device: sender).isValidSignature(signature, for: message))

        let plaintext = try kat.outputBytes("teammates_plaintext")
        #expect(plaintext == sender.deviceID.bytes + (try kat.bytes("senderAnnounceKey")) + signature + payload)
        let box = try AES.GCM.seal(plaintext, using: contentKey, nonce: try AES.GCM.Nonce(data: nonce), authenticating: headerBytes + slotBytes)
        #expect(headerBytes + slotBytes + box.ciphertext + box.tag == file)
    }
}
