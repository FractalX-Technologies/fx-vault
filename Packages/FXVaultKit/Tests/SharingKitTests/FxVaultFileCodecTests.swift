import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// `.fxvault` v1 (§9.1, M6 verify list).
@Suite("fxvault file codec")
struct FxVaultFileCodecTests {
    struct KATFile {
        let header: FxVaultHeaderModel
        let file: Data
        let payload: Data
        let key: Data
    }

    static func katFile() throws -> KATFile {
        let kat = try NearbyKAT.load()
        let header = try FxVaultHeaderModel(
            opsLimit: kat.inputs.fxvault_opsLimit,
            memLimitKiB: kat.inputs.fxvault_memLimitKiB,
            salt: Array(try kat.bytes(kat.inputs.fxvault_salt)),
            nonce: Array(try kat.bytes(kat.inputs.fxvault_nonce))
        )
        let file = try kat.bytes(try kat.output("fxvault_header")) + kat.bytes(try kat.output("fxvault_ciphertext_and_tag"))
        return KATFile(
            header: header,
            file: file,
            payload: Data(kat.inputs.fxvault_payload_utf8.utf8),
            key: try kat.bytes(kat.inputs.fxvault_key)
        )
    }

    static let passphrase = SecretBytes(utf8: "abacus-abdomen-abdominal-abide-abiding-ability")

    // MARK: - Known answers

    @Test func headerMatchesTheVector() throws {
        let kat = try NearbyKAT.load()
        let vector = try Self.katFile()
        #expect(vector.header.encoded().hex == (try kat.output("fxvault_header")))
        #expect(vector.header.encoded().count == Limits.shareHeaderBytes)
        #expect(vector.file.count == Int(try kat.output("fxvault_file_length")))
        #expect(try FxVaultHeaderModel.parse(vector.file) == vector.header)
    }

    @Test func sealingWithTheVectorInputsReproducesTheFile() async throws {
        let vector = try Self.katFile()
        let codec = FxVaultFileCodec(deriver: FixedKeyDeriver(key: vector.key))
        let sealed = try await codec.encrypt(payload: SecretBytes(vector.payload), passphrase: Self.passphrase, header: vector.header)
        #expect(sealed == vector.file)
    }

    @Test func decryptingTheVectorYieldsThePayload() async throws {
        let vector = try Self.katFile()
        let codec = FxVaultFileCodec(deriver: FixedKeyDeriver(key: vector.key))
        let plaintext = try await codec.decrypt(vector.file, passphrase: Self.passphrase)
        #expect(plaintext.withUnsafeBytes { Data($0) } == vector.payload)
    }

    // MARK: - Tampering

    @Test(arguments: 0..<64)
    func flippingAnyHeaderByteFails(_ offset: Int) async throws {
        let vector = try Self.katFile()
        let codec = FxVaultFileCodec(deriver: FixedKeyDeriver(key: vector.key))
        var tampered = vector.file
        tampered[offset] ^= 0x01
        await #expect(throws: ShareError.invalidFile) {
            _ = try await codec.decrypt(tampered, passphrase: Self.passphrase)
        }
    }

    @Test func flippingCiphertextOrTagFails() async throws {
        let vector = try Self.katFile()
        let codec = FxVaultFileCodec(deriver: FixedKeyDeriver(key: vector.key))
        for offset in Limits.shareHeaderBytes..<vector.file.count {
            var tampered = vector.file
            tampered[offset] ^= 0x80
            await #expect(throws: ShareError.invalidFile) {
                _ = try await codec.decrypt(tampered, passphrase: Self.passphrase)
            }
        }
    }

    @Test func truncatedTagFails() async throws {
        let vector = try Self.katFile()
        let codec = FxVaultFileCodec(deriver: FixedKeyDeriver(key: vector.key))
        await #expect(throws: ShareError.invalidFile) {
            _ = try await codec.decrypt(vector.file.dropLast(), passphrase: Self.passphrase)
        }
        await #expect(throws: ShareError.invalidFile) {
            _ = try await codec.decrypt(vector.file.prefix(Limits.shareHeaderBytes + Limits.gcmTagBytes - 1), passphrase: Self.passphrase)
        }
    }

    @Test func changedCostParametersFailAuthentication() async throws {
        // t and m inside bounds but different from what was sealed: the header (AAD) no longer
        // matches, even if the derived key were the same.
        let vector = try Self.katFile()
        let codec = FxVaultFileCodec(deriver: FixedKeyDeriver(key: vector.key))
        for (offset, value) in [(14, UInt32(4)), (18, UInt32(65_537))] {
            var tampered = vector.file
            var bigEndian = value.bigEndian
            tampered.replaceSubrange(offset..<(offset + 4), with: Data(bytes: &bigEndian, count: 4))
            #expect(throws: Never.self) { _ = try FxVaultHeaderModel.parse(tampered) }
            await #expect(throws: ShareError.invalidFile) {
                _ = try await codec.decrypt(tampered, passphrase: Self.passphrase)
            }
        }
    }

    @Test func wrongPassphraseFails() async throws {
        let codec = FxVaultFileCodec(deriver: FakeKeyDeriver())
        let file = try await codec.encrypt(payload: SecretBytes(utf8: "{}"), passphrase: Self.passphrase)
        await #expect(throws: ShareError.invalidFile) {
            _ = try await codec.decrypt(file, passphrase: SecretBytes(utf8: "other-words"))
        }
    }

    // MARK: - Bounds before the KDF

    /// (description, offset, replacement bytes)
    static let rejectedHeaders: [(String, Int, [UInt8])] = [
        ("magic", 0, [0x47]),
        ("format version 2", 8, [0x00, 0x02]),
        ("header length 63", 10, [0x00, 0x3F]),
        ("header length 65", 10, [0x00, 0x41]),
        ("header length 128", 10, [0x00, 0x80]),
        ("kdf id 2", 12, [0x02]),
        ("aead id 2", 13, [0x02]),
        ("ops limit 0", 14, [0, 0, 0, 0]),
        ("ops limit 11", 14, [0, 0, 0, 11]),
        ("memory 8191 KiB", 18, [0, 0, 0x1F, 0xFF]),
        ("memory above 1 GiB", 18, [0, 0x10, 0, 0x01]),
        ("parallelism 2", 22, [0x02]),
        ("flags 1", 23, [0x01]),
        ("reserved byte", 52, [0x01]),
        ("last reserved byte", 63, [0x01]),
    ]

    @Test(arguments: 0..<rejectedHeaders.count)
    func boundsAreRejectedBeforeTheKDF(_ index: Int) async throws {
        let (_, offset, bytes) = Self.rejectedHeaders[index]
        let vector = try Self.katFile()
        var tampered = vector.file
        tampered.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        let spy = SpyKeyDeriver()
        let codec = FxVaultFileCodec(deriver: spy)
        #expect(throws: ShareError.invalidFile) { _ = try FxVaultFileCodec.inspect(tampered) }
        await #expect(throws: ShareError.invalidFile) {
            _ = try await codec.decrypt(tampered, passphrase: Self.passphrase)
        }
        #expect(spy.callCount == 0)
    }

    @Test func sizeLimitsAreRejectedBeforeTheKDF() async throws {
        let vector = try Self.katFile()
        let spy = SpyKeyDeriver()
        let codec = FxVaultFileCodec(deriver: spy)
        let oversize = vector.file + Data(count: Limits.maxShareFileBytes - vector.file.count + 1)
        let tooSmall = vector.file.prefix(Limits.shareHeaderBytes)
        for file in [oversize, tooSmall, Data()] {
            await #expect(throws: ShareError.invalidFile) {
                _ = try await codec.decrypt(file, passphrase: Self.passphrase)
            }
        }
        #expect(spy.callCount == 0)
    }

    @Test func boundaryCostsAreAccepted() throws {
        for (ops, memory) in [
            (UInt32(Limits.shareKDFOpsLimitMin), UInt32(Limits.shareKDFMemoryKiBMin)),
            (UInt32(Limits.shareKDFOpsLimitMax), UInt32(Limits.shareKDFMemoryKiBMax)),
        ] {
            let header = try FxVaultHeaderModel(opsLimit: ops, memLimitKiB: memory, salt: Array(repeating: 1, count: 16), nonce: Array(repeating: 2, count: 12))
            #expect(try FxVaultHeaderModel.parse(header.encoded() + Data(count: Limits.gcmTagBytes)) == header)
        }
    }

    @Test func validHeaderReachesTheKDFExactlyOnce() async throws {
        let spy = SpyKeyDeriver()
        let codec = FxVaultFileCodec(deriver: spy)
        let file = try await codec.encrypt(payload: SecretBytes(utf8: "{}"), passphrase: Self.passphrase)
        _ = try await codec.decrypt(file, passphrase: Self.passphrase)
        #expect(spy.callCount == 2)
    }

    // MARK: - Round trip and freshness

    @Test func sealAndOpenRoundTripAPackage() async throws {
        let codec = FxVaultFileCodec(deriver: FakeKeyDeriver())
        let package = PackageFactory.sample()
        let file = try await codec.seal(package, passphrase: Self.passphrase)
        let header = try FxVaultFileCodec.inspect(file)
        #expect(header.opsLimit == UInt32(Limits.shareKDFOpsLimit))
        #expect(header.memLimitKiB == UInt32(Limits.shareKDFMemoryKiB))
        let opened = try await codec.open(file, passphrase: Self.passphrase)
        #expect(opened.packageID == package.packageID)
        #expect(opened.flattenedItems.map { $0.item.value?.utf8String() } == package.flattenedItems.map { $0.item.value?.utf8String() })
        #expect(opened.manifest() == package.manifest())
    }

    @Test func everyExportHasAFreshSaltAndNonce() async throws {
        let codec = FxVaultFileCodec(deriver: FakeKeyDeriver())
        let first = try FxVaultFileCodec.inspect(try await codec.encrypt(payload: SecretBytes(utf8: "{}"), passphrase: Self.passphrase))
        let second = try FxVaultFileCodec.inspect(try await codec.encrypt(payload: SecretBytes(utf8: "{}"), passphrase: Self.passphrase))
        #expect(first.salt != second.salt)
        #expect(first.nonce != second.nonce)
    }

    @Test func invalidPackagesAreNotSealed() async throws {
        let codec = FxVaultFileCodec(deriver: FakeKeyDeriver())
        var package = PackageFactory.sample()
        package.repository.host = "github.example.com"
        await #expect(throws: ShareError.invalidPackage(.invalidHost)) {
            _ = try await codec.seal(package, passphrase: Self.passphrase)
        }
    }

    @Test func openRejectsAValidFileWithAnInvalidPackage() async throws {
        let codec = FxVaultFileCodec(deriver: FakeKeyDeriver())
        var package = PackageFactory.sample()
        package.schemaVersion = SharePackageModel.currentSchemaVersion + 1
        let json = try SharePackageCoder.encode(package)
        let file = try await codec.encrypt(payload: json, passphrase: Self.passphrase)
        await #expect(throws: ShareError.invalidPackage(.unsupportedSchemaVersion(SharePackageModel.currentSchemaVersion + 1))) {
            _ = try await codec.open(file, passphrase: Self.passphrase)
        }
        // Non-JSON plaintext is a damaged file.
        let garbage = try await codec.encrypt(payload: SecretBytes(utf8: "not json"), passphrase: Self.passphrase)
        await #expect(throws: ShareError.invalidFile) {
            _ = try await codec.open(garbage, passphrase: Self.passphrase)
        }
    }

    @Test func cancellationDuringKeyDerivation() async throws {
        let vector = try Self.katFile()
        let codec = FxVaultFileCodec(deriver: CancellingKeyDeriver())
        await #expect(throws: ShareError.cancelled) {
            _ = try await codec.decrypt(vector.file, passphrase: Self.passphrase)
        }
    }

    @Test func headerInitRejectsWrongSizes() {
        #expect(throws: ShareError.invalidFile) {
            _ = try FxVaultHeaderModel(opsLimit: 3, memLimitKiB: 65_536, salt: [1], nonce: Array(repeating: 0, count: 12))
        }
        #expect(throws: ShareError.invalidFile) {
            _ = try FxVaultHeaderModel(opsLimit: 3, memLimitKiB: 65_536, salt: Array(repeating: 0, count: 16), nonce: [1])
        }
    }
}
