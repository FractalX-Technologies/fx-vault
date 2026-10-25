import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// Known-answer tests for `.fxvault` format 2 (v0.9.0) against Fixtures/file_v2_kat.json, made by
/// Fixtures/kat/file_v2_kat.py. Passphrase mode is reproduced byte for byte. The teammates file
/// 0.9 wrote stays in the fixture: 1.0 dropped that mode and must refuse it as a damaged file.
@Suite("fxvault format 2 known-answer vectors")
struct FxVaultFileV2KATTests {
    static func load() throws -> KATDocument {
        try KATDocument.load("file_v2_kat.json")
    }

    static let passphrase = SecretBytes(utf8: "abacus-abdomen-abdominal-abide-abiding-ability")

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

    // MARK: - 0.9 teammates files

    @Test func aTeammatesFileFromZeroNineIsRefusedBeforeAnyKeyIsDerived() async throws {
        let file = try Self.load().outputBytes("teammates_file")
        let spy = SpyKeyDeriver()
        #expect(throws: ShareError.invalidFile) { _ = try FxVaultFileV2Codec.inspect(file) }
        await #expect(throws: ShareError.invalidFile) {
            _ = try await FxVaultFileV2Codec(deriver: spy).openWithPassphrase(file, passphrase: Self.passphrase)
        }
        #expect(spy.callCount == 0)
    }
}
