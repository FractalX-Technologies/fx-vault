import CryptoKit
import Foundation
import os
import Testing
import VaultCore
@testable import VaultCrypto

// MARK: - Fixtures

/// The known-answer vectors written by Fixtures/kat/generate_kat.py (argon2-cffi + pyca/cryptography).
struct KATVectors: Decodable {
    struct Argon2idVector: Decodable {
        let label: String
        let text: String
        let pwUtf8Hex: String
        let saltHex: String
        let ops: UInt32
        let memBytes: UInt64
        let outHex: String
        let moderate: Bool
    }

    struct Fingerprint: Decodable {
        let row: String
        let valueHex: String
        let outHex: String
    }

    struct Hierarchy: Decodable {
        let dekHex: String
        let vaultIdHex: String
        let kFieldHex: String
        let kFpHex: String
        let kcvHex: String
        let recoveryMaterialHex: String
        let recoveryKekHex: String
        let fingerprint: Fingerprint
    }

    struct FieldVector: Decodable {
        let label: String
        let aesKHex: String
        let table: String
        let column: String
        let row: String
        let repo: String
        let env: String?
        let kind: String
        let name: String
        let dekVersion: UInt32
        let plainHex: String
        let nonceHex: String
        let aadHex: String
        let blobHex: String
    }

    /// A folder item value (v0.7.0): the field layout with the folder as container.
    struct FolderFieldVector: Decodable {
        let label: String
        let aesKHex: String
        let row: String
        let folder: String
        let kind: String
        let name: String
        let dekVersion: UInt32
        let plainHex: String
        let nonceHex: String
        let aadHex: String
        let blobHex: String
    }

    struct DestinationFieldVector: Decodable {
        let label: String
        let aesKHex: String
        let row: String
        let destination: String
        let kind: String
        let name: String
        let dekVersion: UInt32
        let plainHex: String
        let nonceHex: String
        let aadHex: String
        let blobHex: String
    }

    struct OrganizationFieldVector: Decodable {
        let label: String
        let aesKHex: String
        let row: String
        let organization: String
        let kind: String
        let name: String
        let dekVersion: UInt32
        let plainHex: String
        let nonceHex: String
        let aadHex: String
        let blobHex: String
    }

    struct FolderFileVector: Decodable {
        let label: String
        let aesKHex: String
        let file: String
        let dekVersion: UInt32
        let plainHex: String
        let nonceHex: String
        let aadHex: String
        let blobHex: String
    }

    struct PasswordWrap: Decodable {
        let text: String
        let saltHex: String
        let ops: UInt32
        let memBytes: UInt64
        let vaultIdHex: String
        let dekVersion: UInt32
        let dekHex: String
        let kekHex: String
        let nonceHex: String
        let aadHex: String
        let wrappedHex: String
    }

    struct RecoveryWrap: Decodable {
        let materialHex: String
        let vaultIdHex: String
        let dekVersion: UInt32
        let dekHex: String
        let kekHex: String
        let nonceHex: String
        let aadHex: String
        let wrappedHex: String
    }

    struct Wraps: Decodable {
        let password: PasswordWrap
        let recovery: RecoveryWrap
    }

    struct RecoveryVector: Decodable {
        let materialHex: String
        let checksumHex: String
        let text: String
        let groups: [String]
    }

    struct CrockfordVector: Decodable {
        let inHex: String
        let text: String
    }

    let argon2id: [Argon2idVector]
    let hierarchy: Hierarchy
    let field: [FieldVector]
    let folderField: [FolderFieldVector]
    let destinationField: [DestinationFieldVector]
    let organizationField: [OrganizationFieldVector]
    let folderFile: [FolderFileVector]
    let wrap: Wraps
    let recovery: [RecoveryVector]
    let crockford: [CrockfordVector]

    static func load() throws -> KATVectors {
        let url = try #require(
            Bundle.module.url(forResource: "kat_vectors", withExtension: "json", subdirectory: "Fixtures/kat")
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(KATVectors.self, from: Data(contentsOf: url))
    }
}

// MARK: - Fake and spy derivers (§12.2)

/// A fast deterministic stand-in for Argon2id: HKDF over the passphrase, bound to the salt and
/// both cost parameters so any parameter change yields a different key.
struct FakeKeyDeriver: PasswordKeyDeriving {
    func deriveKey(passphrase: SecretBytes, salt: Data, opsLimit: UInt32, memLimitBytes: UInt64) throws -> SymmetricKey {
        let material = passphrase.withUnsafeBytes { SymmetricKey(data: $0) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: salt,
            info: Data("fake-kdf|\(opsLimit)|\(memLimitBytes)".utf8),
            outputByteCount: CryptoDomain.symmetricKeyBytes
        )
    }
}

/// Records every call, then delegates to ``FakeKeyDeriver``.
final class SpyKeyDeriver: PasswordKeyDeriving {
    struct Call: Equatable {
        let passphrase: Data
        let salt: Data
        let opsLimit: UInt32
        let memLimitBytes: UInt64
    }

    private let recorded = OSAllocatedUnfairLock<[Call]>(initialState: [])

    var calls: [Call] {
        recorded.withLock { $0 }
    }

    func deriveKey(passphrase: SecretBytes, salt: Data, opsLimit: UInt32, memLimitBytes: UInt64) throws -> SymmetricKey {
        let call = Call(
            passphrase: passphrase.withUnsafeBytes { Data($0) },
            salt: salt,
            opsLimit: opsLimit,
            memLimitBytes: memLimitBytes
        )
        recorded.withLock { $0.append(call) }
        return try FakeKeyDeriver().deriveKey(
            passphrase: passphrase,
            salt: salt,
            opsLimit: opsLimit,
            memLimitBytes: memLimitBytes
        )
    }
}

/// A deriver that always fails, to show KDF errors propagate unchanged.
struct FailingKeyDeriver: PasswordKeyDeriving {
    func deriveKey(passphrase: SecretBytes, salt: Data, opsLimit: UInt32, memLimitBytes: UInt64) throws -> SymmetricKey {
        throw CryptoError.kdfFailed
    }
}

// MARK: - Helpers

enum TestData {
    static let vaultID = Data(repeating: 0x60, count: Limits.vaultIDBytes)

    static func keys(dekVersion: UInt32 = UnlockedKeys.initialDEKVersion) throws -> UnlockedKeys {
        try UnlockedKeys.generate(vaultID: vaultID, dekVersion: dekVersion)
    }

    static func field(
        location: FieldLocation = .configItemValue,
        environmentID: EnvironmentID? = EnvironmentID(),
        kind: ConfigKind = .secret,
        name: String = "FXV_FIXTURE_NAME"
    ) -> FieldAAD {
        FieldAAD(
            location: location,
            rowID: ConfigItemID(),
            repositoryID: RepoID(),
            environmentID: environmentID,
            kind: kind,
            name: name
        )
    }

    static let logger = Logger(subsystem: "io.fractalx.fxvault.tests", category: "vaultcrypto")
}

extension Data {
    /// Parses lowercase or uppercase hex; nil for odd length or a non-hex character.
    init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard
                let high = Self.nibble(digits[index]),
                let low = Self.nibble(digits[index + 1])
            else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// A copy with byte `index` XOR-ed with `mask`.
    func flipping(byteAt index: Int, mask: UInt8 = 0x01) -> Data {
        var copy = self
        copy[copy.startIndex + index] ^= mask
        return copy
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

/// Hex of a KAT field, failing the test when it is malformed.
func hexData(_ hex: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Data {
    try #require(Data(hex: hex), sourceLocation: sourceLocation)
}

extension SymmetricKey {
    var rawData: Data {
        withUnsafeBytes { Data($0) }
    }
}
