import Foundation
import VaultCore

/// The fixed 64-byte `.fxvault` format 2 header (v0.9.0, SHARING-PROTOCOL.md §2.1). The same
/// magic as v1; the header (and in teammates mode every recipient slot after it) is the AES-GCM
/// AAD, so every byte is authenticated.
///
/// | Offset | Size | Field |
/// |---|---|---|
/// | 0 | 8 | magic `46 58 56 41 55 4C 54 1A` |
/// | 8 | 2 | formatVersion u16 BE = 2 |
/// | 10 | 2 | headerLength u16 BE = 64 |
/// | 12 | 1 | kdfId: 1 Argon2id (passphrase), 0 none (teammates) |
/// | 13 | 1 | aeadId = 1 (AES-256-GCM) |
/// | 14 | 4 | opsLimit u32 BE (passphrase: v1 bounds; teammates: 0) |
/// | 18 | 4 | memLimitKiB u32 BE (passphrase: v1 bounds; teammates: 0) |
/// | 22 | 1 | parallelism (passphrase 1, teammates 0) |
/// | 23 | 1 | flags = 0 |
/// | 24 | 16 | salt (Argon2id salt, or the slot-id salt) |
/// | 40 | 12 | nonce |
/// | 52 | 1 | mode: 1 passphrase, 2 teammates |
/// | 53 | 1 | recipientCount: 0 (passphrase), 1…``Limits/maxShareRecipients`` (teammates) |
/// | 54 | 10 | reserved (zero) |
public struct FxVaultHeaderV2Model: Sendable, Hashable {
    /// How the content key is obtained.
    public enum Mode: UInt8, Sendable, Hashable {
        /// Argon2id over a six-word passphrase, as in v1.
        case passphrase = 1
        /// A random content key wrapped with HPKE for each recipient teammate.
        case teammates = 2
    }

    /// The format version of this layout.
    public static let formatVersion: UInt16 = 2
    /// The header length; any other value is rejected.
    public static let headerLength = UInt16(Limits.shareHeaderBytes)
    /// KDF id of a teammates file: no key derivation.
    public static let kdfNone: UInt8 = 0

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

    public let mode: Mode
    /// Argon2id `t` (passphrase mode); 0 in teammates mode.
    public let opsLimit: UInt32
    /// Argon2id `m` in KiB (passphrase mode); 0 in teammates mode.
    public let memLimitKiB: UInt32
    /// The Argon2id salt (passphrase) or the salt of the recipient slot ids (teammates).
    public let salt: [UInt8]
    /// The AES-GCM nonce.
    public let nonce: [UInt8]
    /// Recipient slots that follow the header: 0 in passphrase mode.
    public let recipientCount: Int

    /// A passphrase-mode header; checks the v1 cost bounds and sizes.
    public init(passphraseOpsLimit opsLimit: UInt32, memLimitKiB: UInt32, salt: [UInt8], nonce: [UInt8]) throws(ShareError) {
        let opsRange = UInt32(Limits.shareKDFOpsLimitMin)...UInt32(Limits.shareKDFOpsLimitMax)
        let memoryRange = UInt32(Limits.shareKDFMemoryKiBMin)...UInt32(Limits.shareKDFMemoryKiBMax)
        guard opsRange.contains(opsLimit),
              memoryRange.contains(memLimitKiB),
              salt.count == Limits.kdfSaltBytes,
              nonce.count == Limits.gcmNonceBytes
        else { throw .invalidFile }
        mode = .passphrase
        self.opsLimit = opsLimit
        self.memLimitKiB = memLimitKiB
        self.salt = salt
        self.nonce = nonce
        recipientCount = 0
    }

    /// A teammates-mode header for `recipientCount` slots.
    public init(teammatesRecipientCount recipientCount: Int, salt: [UInt8], nonce: [UInt8]) throws(ShareError) {
        guard (1...Limits.maxShareRecipients).contains(recipientCount),
              salt.count == Limits.kdfSaltBytes,
              nonce.count == Limits.gcmNonceBytes
        else { throw .invalidFile }
        mode = .teammates
        opsLimit = 0
        memLimitKiB = 0
        self.salt = salt
        self.nonce = nonce
        self.recipientCount = recipientCount
    }

    /// A passphrase-mode header for a new export: default cost (t=3, 64 MiB), fresh salt and nonce.
    public static func freshPassphrase() -> FxVaultHeaderV2Model {
        // The defaults are inside the bounds checked by the public init.
        FxVaultHeaderV2Model(
            unchecked: .passphrase,
            opsLimit: UInt32(Limits.shareKDFOpsLimit),
            memLimitKiB: UInt32(Limits.shareKDFMemoryKiB),
            salt: randomBytes(Limits.kdfSaltBytes),
            nonce: randomBytes(Limits.gcmNonceBytes),
            recipientCount: 0
        )
    }

    /// A teammates-mode header for a new export with a fresh salt and nonce. Throws
    /// `encryptionFailed` when `recipientCount` is outside 1…``Limits/maxShareRecipients``.
    public static func freshTeammates(recipientCount: Int) throws(ShareError) -> FxVaultHeaderV2Model {
        do {
            return try FxVaultHeaderV2Model(
                teammatesRecipientCount: recipientCount,
                salt: randomBytes(Limits.kdfSaltBytes),
                nonce: randomBytes(Limits.gcmNonceBytes)
            )
        } catch {
            throw .encryptionFailed
        }
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
        switch mode {
        case .passphrase:
            data.append(FxVaultHeaderModel.kdfArgon2id)
            data.append(FxVaultHeaderModel.aeadAES256GCM)
            data.appendBigEndian(opsLimit)
            data.appendBigEndian(memLimitKiB)
            data.append(FxVaultHeaderModel.requiredParallelism)
        case .teammates:
            data.append(Self.kdfNone)
            data.append(FxVaultHeaderModel.aeadAES256GCM)
            data.appendBigEndian(UInt32.zero)
            data.appendBigEndian(UInt32.zero)
            data.append(UInt8.zero)
        }
        data.append(FxVaultHeaderModel.requiredFlags)
        data.append(contentsOf: salt)
        data.append(contentsOf: nonce)
        data.append(mode.rawValue)
        data.append(UInt8(recipientCount))
        data.append(Data(count: Int(Self.headerLength) - data.count))
        return data
    }

    /// Parses and checks a format 2 header: magic, version, header length, then the fields of its
    /// mode (ids, cost bounds or zeros, recipient count) and the reserved bytes. `bytes` may be
    /// the whole file. Every failure is `ShareError.invalidFile`.
    public static func parse(_ bytes: Data) throws(ShareError) -> FxVaultHeaderV2Model {
        guard bytes.count >= Int(headerLength),
              bytes.bytes(at: Offset.magic, length: FxVaultHeaderModel.magic.count) == Data(FxVaultHeaderModel.magic),
              bytes.readBigEndian(UInt16.self, at: Offset.formatVersion) == formatVersion,
              bytes.readBigEndian(UInt16.self, at: Offset.headerLength) == headerLength,
              let kdfID = bytes.readBigEndian(UInt8.self, at: Offset.kdfID),
              bytes.readBigEndian(UInt8.self, at: Offset.aeadID) == FxVaultHeaderModel.aeadAES256GCM,
              let opsLimit = bytes.readBigEndian(UInt32.self, at: Offset.opsLimit),
              let memLimitKiB = bytes.readBigEndian(UInt32.self, at: Offset.memLimitKiB),
              let parallelism = bytes.readBigEndian(UInt8.self, at: Offset.parallelism),
              bytes.readBigEndian(UInt8.self, at: Offset.flags) == FxVaultHeaderModel.requiredFlags,
              let salt = bytes.bytes(at: Offset.salt, length: Limits.kdfSaltBytes),
              let nonce = bytes.bytes(at: Offset.nonce, length: Limits.gcmNonceBytes),
              let modeByte = bytes.readBigEndian(UInt8.self, at: Offset.mode),
              let mode = Mode(rawValue: modeByte),
              let recipientCount = bytes.readBigEndian(UInt8.self, at: Offset.recipientCount),
              let reserved = bytes.bytes(at: Offset.reserved, length: Int(headerLength) - Offset.reserved),
              reserved.allSatisfy({ $0 == 0 })
        else { throw .invalidFile }
        switch mode {
        case .passphrase:
            guard kdfID == FxVaultHeaderModel.kdfArgon2id,
                  parallelism == FxVaultHeaderModel.requiredParallelism,
                  recipientCount == 0
            else { throw .invalidFile }
            return try FxVaultHeaderV2Model(
                passphraseOpsLimit: opsLimit,
                memLimitKiB: memLimitKiB,
                salt: Array(salt),
                nonce: Array(nonce)
            )
        case .teammates:
            guard kdfID == kdfNone, opsLimit == 0, memLimitKiB == 0, parallelism == 0 else { throw .invalidFile }
            return try FxVaultHeaderV2Model(
                teammatesRecipientCount: Int(recipientCount),
                salt: Array(salt),
                nonce: Array(nonce)
            )
        }
    }

    private init(
        unchecked mode: Mode,
        opsLimit: UInt32,
        memLimitKiB: UInt32,
        salt: [UInt8],
        nonce: [UInt8],
        recipientCount: Int
    ) {
        self.mode = mode
        self.opsLimit = opsLimit
        self.memLimitKiB = memLimitKiB
        self.salt = salt
        self.nonce = nonce
        self.recipientCount = recipientCount
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}
