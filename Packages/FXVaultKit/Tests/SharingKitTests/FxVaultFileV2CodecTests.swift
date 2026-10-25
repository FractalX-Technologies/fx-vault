import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// `.fxvault` format 2 (v0.9.0): passphrase mode, the reader order, tampering and the v1 path.
@Suite("fxvault format 2 codec")
struct FxVaultFileV2CodecTests {
    static let passphrase = SecretBytes(utf8: "abacus-abdomen-abdominal-abide-abiding-ability")
    static let payload = Data(#"{"schema":"io.fractalx.fxvault.share","schemaVersion":4,"scope":"bundle"}"#.utf8)

    // MARK: - Passphrase mode

    @Test func passphraseModeRoundTrips() async throws {
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        let file = try await codec.sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        let info = try FxVaultFileV2Codec.inspect(file)
        guard case .v2Passphrase(let header) = info else {
            Issue.record("expected a passphrase file, got \(info)")
            return
        }
        #expect(header.opsLimit == UInt32(Limits.shareKDFOpsLimit))
        #expect(header.memLimitKiB == UInt32(Limits.shareKDFMemoryKiB))
        #expect(file.count == Limits.shareHeaderBytes + Self.payload.count + Limits.gcmTagBytes)
        let opened = try await codec.openWithPassphrase(file, passphrase: Self.passphrase)
        #expect(opened.withUnsafeBytes { Data($0) } == Self.payload)
    }

    @Test func everyPassphraseExportHasAFreshSaltAndNonce() async throws {
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        let first = try await codec.sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        let second = try await codec.sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        let saltAndNonce = FxVaultHeaderV2Model.Offset.salt..<FxVaultHeaderV2Model.Offset.mode
        #expect(first[saltAndNonce] != second[saltAndNonce])
    }

    @Test func wrongPassphraseFails() async throws {
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        let file = try await codec.sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        await #expect(throws: ShareError.invalidFile) {
            _ = try await codec.openWithPassphrase(file, passphrase: SecretBytes(utf8: "other-words"))
        }
    }

    @Test func cancellationIsReported() async throws {
        let file = try await FxVaultFileV2Codec(deriver: FakeKeyDeriver())
            .sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        await #expect(throws: ShareError.cancelled) {
            _ = try await FxVaultFileV2Codec(deriver: CancellingKeyDeriver()).openWithPassphrase(file, passphrase: Self.passphrase)
        }
    }

    @Test(arguments: 0..<64)
    func flippingAnyPassphraseHeaderByteFails(_ offset: Int) async throws {
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        var file = try await codec.sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        file[offset] ^= 0x01
        await #expect(throws: ShareError.invalidFile) {
            _ = try await codec.openWithPassphrase(file, passphrase: Self.passphrase)
        }
    }

    @Test func flippingPassphraseCiphertextOrTagFails() async throws {
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        let file = try await codec.sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        for offset in Limits.shareHeaderBytes..<file.count {
            var tampered = file
            tampered[offset] ^= 0x80
            await #expect(throws: ShareError.invalidFile) {
                _ = try await codec.openWithPassphrase(tampered, passphrase: Self.passphrase)
            }
        }
    }

    /// (description, offset, replacement bytes) for a valid passphrase-mode header.
    static let rejectedPassphraseHeaders: [(String, Int, [UInt8])] = [
        ("format version 3", 8, [0x00, 0x03]),
        ("header length 65", 10, [0x00, 0x41]),
        ("kdf id 0", 12, [0x00]),
        ("aead id 2", 13, [0x02]),
        ("ops limit 0", 14, [0, 0, 0, 0]),
        ("ops limit 11", 14, [0, 0, 0, 11]),
        ("memory 8191 KiB", 18, [0, 0, 0x1F, 0xFF]),
        ("parallelism 0", 22, [0x00]),
        ("flags 1", 23, [0x01]),
        ("mode 0", 52, [0x00]),
        ("mode 3", 52, [0x03]),
        ("mode teammates", 52, [0x02]),
        ("one recipient", 53, [0x01]),
        ("first reserved byte", 54, [0x01]),
        ("last reserved byte", 63, [0x01]),
    ]

    @Test(arguments: 0..<rejectedPassphraseHeaders.count)
    func passphraseHeaderBoundsAreRejectedBeforeTheKDF(_ index: Int) async throws {
        let (_, offset, bytes) = Self.rejectedPassphraseHeaders[index]
        var file = try await FxVaultFileV2Codec(deriver: FakeKeyDeriver())
            .sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        file.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        let spy = SpyKeyDeriver()
        #expect(throws: ShareError.invalidFile) { _ = try FxVaultFileV2Codec.inspect(file) }
        await #expect(throws: ShareError.invalidFile) {
            _ = try await FxVaultFileV2Codec(deriver: spy).openWithPassphrase(file, passphrase: Self.passphrase)
        }
        #expect(spy.callCount == 0)
    }

    @Test func inspectingAndSizeChecksNeverDeriveAKey() async throws {
        let spy = SpyKeyDeriver()
        let codec = FxVaultFileV2Codec(deriver: spy)
        let file = try await FxVaultFileV2Codec(deriver: FakeKeyDeriver())
            .sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        _ = try FxVaultFileV2Codec.inspect(file)
        let oversize = file + Data(count: Limits.maxShareFileBytes - file.count + 1)
        let passphraseOversize = file + Data(count: Limits.maxShareFileBytes - file.count + 1)
        for bad in [oversize, passphraseOversize, file.prefix(Limits.shareHeaderBytes + Limits.gcmTagBytes - 1), Data()] {
            #expect(throws: ShareError.invalidFile) { _ = try FxVaultFileV2Codec.inspect(bad) }
            await #expect(throws: ShareError.invalidFile) {
                _ = try await codec.openWithPassphrase(bad, passphrase: Self.passphrase)
            }
        }
        #expect(spy.callCount == 0)
        _ = try await codec.openWithPassphrase(file, passphrase: Self.passphrase)
        #expect(spy.callCount == 1)
    }

    @Test func passphrasePayloadLimitIsEnforced() async throws {
        let codec = FxVaultFileV2Codec(deriver: FakeKeyDeriver())
        await #expect(throws: ShareError.payloadTooLarge) {
            _ = try await codec.sealWithPassphrase(
                payload: SecretBytes(count: Limits.maxSharePayloadBytes + 1),
                passphrase: Self.passphrase
            )
        }
    }

    // MARK: - v1 through the new entry point

    @Test func versionOneFilesStillOpen() async throws {
        let vector = try FxVaultFileCodecTests.katFile()
        #expect(try FxVaultFileV2Codec.inspect(vector.file) == .v1(vector.header))
        let codec = FxVaultFileV2Codec(deriver: FixedKeyDeriver(key: vector.key))
        let opened = try await codec.openWithPassphrase(vector.file, passphrase: Self.passphrase)
        #expect(opened.withUnsafeBytes { Data($0) } == vector.payload)

        let sealed = try await FxVaultFileCodec(deriver: FakeKeyDeriver()).encrypt(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        let reopened = try await FxVaultFileV2Codec(deriver: FakeKeyDeriver()).openWithPassphrase(sealed, passphrase: Self.passphrase)
        #expect(reopened.withUnsafeBytes { Data($0) } == Self.payload)
    }

    @Test func theVersionOneReaderRefusesFormatTwo() async throws {
        let file = try await FxVaultFileV2Codec(deriver: FakeKeyDeriver())
            .sealWithPassphrase(payload: SecretBytes(Self.payload), passphrase: Self.passphrase)
        #expect(throws: ShareError.invalidFile) { _ = try FxVaultFileCodec.inspect(file) }
    }
}
