import Foundation
import VaultCore

/// The fixed 64-byte `.fxvault` v1 header (§9.1, D23). The encoded header is the AES-GCM AAD,
/// so every byte is authenticated.
///
/// | Offset | Size | Field |
/// |---|---|---|
/// | 0 | 8 | magic `46 58 56 41 55 4C 54 1A` |
/// | 8 | 2 | formatVersion u16 BE = 1 |
/// | 10 | 2 | headerLength u16 BE = 64 |
/// | 12 | 1 | kdfId = 1 (Argon2id v1.3) |
/// | 13 | 1 | aeadId = 1 (AES-256-GCM) |
/// | 14 | 4 | opsLimit u32 BE |
/// | 18 | 4 | memLimitKiB u32 BE |
/// | 22 | 1 | parallelism = 1 |
/// | 23 | 1 | flags = 0 |
/// | 24 | 16 | salt |
/// | 40 | 12 | nonce |
/// | 52 | 12 | reserved (zero) |
public struct FxVaultHeaderModel: Sendable, Hashable {
    /// `FXVAULT` followed by 0x1A.
    public static let magic: [UInt8] = [0x46, 0x58, 0x56, 0x41, 0x55, 0x4C, 0x54, 0x1A]
    /// The only format version this build reads and writes.
    public static let formatVersion: UInt16 = 1
    /// The v1 header length; any other value is rejected.
    public static let headerLength = UInt16(Limits.shareHeaderBytes)
    /// KDF id 1: Argon2id v1.3.
    public static let kdfArgon2id: UInt8 = 1
    /// AEAD id 1: AES-256-GCM.
    public static let aeadAES256GCM: UInt8 = 1
    /// The only accepted Argon2id parallelism.
    public static let requiredParallelism: UInt8 = 1
    /// The only accepted flags value.
    public static let requiredFlags: UInt8 = 0

    /// Byte offsets of the v1 layout.
    enum Offset {
        static let magic = 0
        static let formatVersion = 8
        static let headerLength = 10
        static let kdfID = 12
        static let aeadID = 13
        static let opsLimit = 14
        static let memLimitKiB = 18
        static let parallelism = 22
        static let flags = 23
        static let salt = 24
        static let nonce = 40
        static let reserved = 52
    }

    public var opsLimit: UInt32
    public var memLimitKiB: UInt32
    public var salt: [UInt8]
    public var nonce: [UInt8]

    /// Validates bounds and sizes (§9.1 reader step 6).
    public init(opsLimit: UInt32, memLimitKiB: UInt32, salt: [UInt8], nonce: [UInt8]) throws(ShareError) {
        let opsRange = UInt32(Limits.shareKDFOpsLimitMin)...UInt32(Limits.shareKDFOpsLimitMax)
        let memoryRange = UInt32(Limits.shareKDFMemoryKiBMin)...UInt32(Limits.shareKDFMemoryKiBMax)
        guard opsRange.contains(opsLimit),
              memoryRange.contains(memLimitKiB),
              salt.count == Limits.kdfSaltBytes,
              nonce.count == Limits.gcmNonceBytes
        else { throw .invalidFile }
        self.opsLimit = opsLimit
        self.memLimitKiB = memLimitKiB
        self.salt = salt
        self.nonce = nonce
    }

    /// A header for a new export: default cost (t=3, 64 MiB), fresh random salt and nonce.
    public static func fresh() -> FxVaultHeaderModel {
        var generator = SystemRandomNumberGenerator()
        return fresh(using: &generator)
    }

    /// A header for a new export using `generator` for the salt and nonce.
    public static func fresh(using generator: inout some RandomNumberGenerator) -> FxVaultHeaderModel {
        let salt = (0..<Limits.kdfSaltBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let nonce = (0..<Limits.gcmNonceBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        // The defaults are inside the bounds checked by init, so this cannot fail.
        return FxVaultHeaderModel(
            uncheckedOpsLimit: UInt32(Limits.shareKDFOpsLimit),
            memLimitKiB: UInt32(Limits.shareKDFMemoryKiB),
            salt: salt,
            nonce: nonce
        )
    }

    private init(uncheckedOpsLimit: UInt32, memLimitKiB: UInt32, salt: [UInt8], nonce: [UInt8]) {
        opsLimit = uncheckedOpsLimit
        self.memLimitKiB = memLimitKiB
        self.salt = salt
        self.nonce = nonce
    }

    /// The key derivation parameters this header carries.
    public var keyDerivationParameters: KeyDerivationParametersModel {
        KeyDerivationParametersModel(
            opsLimit: opsLimit,
            memLimitKiB: memLimitKiB,
            parallelism: Self.requiredParallelism,
            salt: salt
        )
    }

    /// The exact 64 header bytes (also the AAD).
    public func encoded() -> Data {
        var data = Data(Self.magic)
        data.appendBigEndian(Self.formatVersion)
        data.appendBigEndian(Self.headerLength)
        data.append(Self.kdfArgon2id)
        data.append(Self.aeadAES256GCM)
        data.appendBigEndian(opsLimit)
        data.appendBigEndian(memLimitKiB)
        data.append(Self.requiredParallelism)
        data.append(Self.requiredFlags)
        data.append(contentsOf: salt)
        data.append(contentsOf: nonce)
        data.append(Data(count: Int(Self.headerLength) - data.count))
        return data
    }

    /// Parses and checks a header in the §9.1 reader order (steps 2–6): magic, version,
    /// header length, ids, then bounds and reserved bytes. `bytes` may be the whole file.
    /// Every failure is `ShareError.invalidFile`.
    public static func parse(_ bytes: Data) throws(ShareError) -> FxVaultHeaderModel {
        guard bytes.count >= Int(headerLength),
              bytes.bytes(at: Offset.magic, length: magic.count) == Data(magic),
              bytes.readBigEndian(UInt16.self, at: Offset.formatVersion) == formatVersion,
              bytes.readBigEndian(UInt16.self, at: Offset.headerLength) == headerLength,
              bytes.readBigEndian(UInt8.self, at: Offset.kdfID) == kdfArgon2id,
              bytes.readBigEndian(UInt8.self, at: Offset.aeadID) == aeadAES256GCM,
              let opsLimit = bytes.readBigEndian(UInt32.self, at: Offset.opsLimit),
              let memLimitKiB = bytes.readBigEndian(UInt32.self, at: Offset.memLimitKiB),
              bytes.readBigEndian(UInt8.self, at: Offset.parallelism) == requiredParallelism,
              bytes.readBigEndian(UInt8.self, at: Offset.flags) == requiredFlags,
              let salt = bytes.bytes(at: Offset.salt, length: Limits.kdfSaltBytes),
              let nonce = bytes.bytes(at: Offset.nonce, length: Limits.gcmNonceBytes),
              let reserved = bytes.bytes(at: Offset.reserved, length: Int(headerLength) - Offset.reserved),
              reserved.allSatisfy({ $0 == 0 })
        else { throw .invalidFile }
        return try FxVaultHeaderModel(
            opsLimit: opsLimit,
            memLimitKiB: memLimitKiB,
            salt: Array(salt),
            nonce: Array(nonce)
        )
    }
}
