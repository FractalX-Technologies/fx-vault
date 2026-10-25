import Foundation
import VaultCore

/// The fixed 64-byte `.fxvault` format 2 header (v0.9.0, SHARING-PROTOCOL.md §2.1). The same
/// magic as v1; the header is the AES-GCM AAD, so every byte is authenticated. 1.0 reads and
/// writes passphrase mode only: 0.9's teammates mode (mode 2) is rejected as `invalidFile`.
///
/// | Offset | Size | Field |
/// |---|---|---|
/// | 0 | 8 | magic `46 58 56 41 55 4C 54 1A` |
/// | 8 | 2 | formatVersion u16 BE = 2 |
/// | 10 | 2 | headerLength u16 BE = 64 |
/// | 12 | 1 | kdfId = 1 (Argon2id) |
/// | 13 | 1 | aeadId = 1 (AES-256-GCM) |
/// | 14 | 4 | opsLimit u32 BE (v1 bounds) |
/// | 18 | 4 | memLimitKiB u32 BE (v1 bounds) |
/// | 22 | 1 | parallelism = 1 |
/// | 23 | 1 | flags = 0 |
/// | 24 | 16 | Argon2id salt |
/// | 40 | 12 | nonce |
/// | 52 | 1 | mode = 1 (passphrase) |
/// | 53 | 1 | recipientCount = 0 |
/// | 54 | 10 | reserved (zero) |
public struct FxVaultHeaderV2Model: Sendable, Hashable {
    /// The format version of this layout.
    public static let formatVersion: UInt16 = 2
    /// The header length; any other value is rejected.
    public static let headerLength = UInt16(Limits.shareHeaderBytes)
    /// The mode byte of a passphrase file (Argon2id over six words, as in v1).
    static let passphraseMode: UInt8 = 1

    /// Byte offsets of the format 2 layout (shared with v1 up to the nonce).
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
        static let mode = 52
        static let recipientCount = 53
        static let reserved = 54
    }

    /// Argon2id `t`.
    public let opsLimit: UInt32
    /// Argon2id `m` in KiB.
    public let memLimitKiB: UInt32
    /// The Argon2id salt.
    public let salt: [UInt8]
    /// The AES-GCM nonce.
    public let nonce: [UInt8]

    /// A passphrase-mode header; checks the v1 cost bounds and sizes.
    public init(passphraseOpsLimit opsLimit: UInt32, memLimitKiB: UInt32, salt: [UInt8], nonce: [UInt8]) throws(ShareError) {
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

    /// A passphrase-mode header for a new export: default cost (t=3, 64 MiB), fresh salt and nonce.
    public static func freshPassphrase() -> FxVaultHeaderV2Model {
        // The defaults are inside the bounds checked by the public init.
        FxVaultHeaderV2Model(
            unchecked: UInt32(Limits.shareKDFOpsLimit),
            memLimitKiB: UInt32(Limits.shareKDFMemoryKiB),
            salt: randomBytes(Limits.kdfSaltBytes),
            nonce: randomBytes(Limits.gcmNonceBytes)
        )
    }

    /// The key derivation parameters of a passphrase-mode header.
    public var keyDerivationParameters: KeyDerivationParametersModel {
        KeyDerivationParametersModel(
            opsLimit: opsLimit,
            memLimitKiB: memLimitKiB,
            parallelism: FxVaultHeaderModel.requiredParallelism,
            salt: salt
        )
    }

    /// The exact 64 header bytes.
    public func encoded() -> Data {
        var data = Data(FxVaultHeaderModel.magic)
        data.appendBigEndian(Self.formatVersion)
        data.appendBigEndian(Self.headerLength)
        data.append(FxVaultHeaderModel.kdfArgon2id)
        data.append(FxVaultHeaderModel.aeadAES256GCM)
        data.appendBigEndian(opsLimit)
        data.appendBigEndian(memLimitKiB)
        data.append(FxVaultHeaderModel.requiredParallelism)
        data.append(FxVaultHeaderModel.requiredFlags)
        data.append(contentsOf: salt)
        data.append(contentsOf: nonce)
        data.append(Self.passphraseMode)
        data.append(UInt8.zero)
        data.append(Data(count: Int(Self.headerLength) - data.count))
        return data
    }

    /// Parses and checks a format 2 header: magic, version, header length, ids, cost bounds,
    /// passphrase mode with no recipients, and the reserved bytes. `bytes` may be
    /// the whole file. Every failure is `ShareError.invalidFile`.
    public static func parse(_ bytes: Data) throws(ShareError) -> FxVaultHeaderV2Model {
        guard bytes.count >= Int(headerLength),
              bytes.bytes(at: Offset.magic, length: FxVaultHeaderModel.magic.count) == Data(FxVaultHeaderModel.magic),
              bytes.readBigEndian(UInt16.self, at: Offset.formatVersion) == formatVersion,
              bytes.readBigEndian(UInt16.self, at: Offset.headerLength) == headerLength,
              bytes.readBigEndian(UInt8.self, at: Offset.kdfID) == FxVaultHeaderModel.kdfArgon2id,
              bytes.readBigEndian(UInt8.self, at: Offset.aeadID) == FxVaultHeaderModel.aeadAES256GCM,
              let opsLimit = bytes.readBigEndian(UInt32.self, at: Offset.opsLimit),
              let memLimitKiB = bytes.readBigEndian(UInt32.self, at: Offset.memLimitKiB),
              bytes.readBigEndian(UInt8.self, at: Offset.parallelism) == FxVaultHeaderModel.requiredParallelism,
              bytes.readBigEndian(UInt8.self, at: Offset.flags) == FxVaultHeaderModel.requiredFlags,
              let salt = bytes.bytes(at: Offset.salt, length: Limits.kdfSaltBytes),
              let nonce = bytes.bytes(at: Offset.nonce, length: Limits.gcmNonceBytes),
              bytes.readBigEndian(UInt8.self, at: Offset.mode) == passphraseMode,
              bytes.readBigEndian(UInt8.self, at: Offset.recipientCount) == 0,
              let reserved = bytes.bytes(at: Offset.reserved, length: Int(headerLength) - Offset.reserved),
              reserved.allSatisfy({ $0 == 0 })
        else { throw .invalidFile }
        return try FxVaultHeaderV2Model(
            passphraseOpsLimit: opsLimit,
            memLimitKiB: memLimitKiB,
            salt: Array(salt),
            nonce: Array(nonce)
        )
    }

    private init(unchecked opsLimit: UInt32, memLimitKiB: UInt32, salt: [UInt8], nonce: [UInt8]) {
        self.opsLimit = opsLimit
        self.memLimitKiB = memLimitKiB
        self.salt = salt
        self.nonce = nonce
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
