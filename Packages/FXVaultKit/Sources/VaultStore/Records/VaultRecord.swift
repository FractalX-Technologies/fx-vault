import Foundation
import GRDB

/// The single `vaults` row (§6 `v1_vault`): vault identity, key check value and unlock
/// bookkeeping. Holds no key material; VaultStore never interprets the blobs.
public struct VaultRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "vaults"

    /// The only allowed primary key (`CHECK (id = 1)`).
    public static let singletonID = 1
    /// `format_version` and `dek_version` of a new vault.
    public static let initialVersion = 1

    /// Always ``singletonID``.
    public var id: Int
    /// 16 random bytes identifying this vault (bound into the AAD, §5.4).
    public var vaultID: Data
    public var formatVersion: Int
    /// Incremented on every DEK rotation.
    public var dekVersion: Int
    /// 16-byte key check value of the current DEK (§5.1).
    public var kcv: Data
    /// Touch ID enrollment fingerprint (`evaluatedPolicyDomainState` hash), if enabled.
    public var biometryStateHash: Data?
    public var lastPasswordUnlockAt: Date?
    /// `kern.bootsessionuuid` at the last password unlock (restart rule, §5.5).
    public var lastPasswordBootSession: String?
    public var createdAt: Date

    public init(
        vaultID: Data,
        formatVersion: Int = VaultRecord.initialVersion,
        dekVersion: Int = VaultRecord.initialVersion,
        kcv: Data,
        biometryStateHash: Data? = nil,
        lastPasswordUnlockAt: Date? = nil,
        lastPasswordBootSession: String? = nil,
        createdAt: Date
    ) {
        id = Self.singletonID
        self.vaultID = vaultID
        self.formatVersion = formatVersion
        self.dekVersion = dekVersion
        self.kcv = kcv
        self.biometryStateHash = biometryStateHash
        self.lastPasswordUnlockAt = lastPasswordUnlockAt
        self.lastPasswordBootSession = lastPasswordBootSession
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case vaultID = "vault_id"
        case formatVersion = "format_version"
        case dekVersion = "dek_version"
        case kcv
        case biometryStateHash = "biometry_state_hash"
        case lastPasswordUnlockAt = "last_password_unlock_at"
        case lastPasswordBootSession = "last_password_boot_session"
        case createdAt = "created_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}

/// `key_wraps.method`: which credential wraps the DEK.
public enum KeyWrapMethod: String, Sendable, Hashable, Codable, CaseIterable {
    case password
    case recovery
}

/// `key_wraps.kdf_alg`: how the wrapping key is derived (§5.1).
public enum KeyWrapKDF: Int, Sendable, Hashable, Codable, CaseIterable {
    /// Argon2id v1.3 over the NFC master password (needs ops, memory and a 16-byte salt).
    case argon2id13 = 1
    /// HKDF-SHA256 over the recovery key.
    case hkdfSHA256 = 2
}

/// One `key_wraps` row (§6 `v1_vault`): the DEK wrapped by one credential (§5.2, 62 bytes).
public struct KeyWrapRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "key_wraps"

    public var method: KeyWrapMethod
    public var kdf: KeyWrapKDF
    /// Argon2id ops limit; nil for HKDF.
    public var opsLimit: Int?
    /// Argon2id memory limit in bytes; nil for HKDF.
    public var memLimitBytes: Int?
    /// Argon2id salt (16 bytes); nil for HKDF.
    public var salt: Data?
    /// The wrapped DEK, opaque to VaultStore (62 bytes, §5.2).
    public var wrappedDEK: Data
    /// The `vaults.dek_version` this wrap holds.
    public var dekVersion: Int
    public var updatedAt: Date

    public init(
        method: KeyWrapMethod,
        kdf: KeyWrapKDF,
        opsLimit: Int? = nil,
        memLimitBytes: Int? = nil,
        salt: Data? = nil,
        wrappedDEK: Data,
        dekVersion: Int,
        updatedAt: Date
    ) {
        self.method = method
        self.kdf = kdf
        self.opsLimit = opsLimit
        self.memLimitBytes = memLimitBytes
        self.salt = salt
        self.wrappedDEK = wrappedDEK
        self.dekVersion = dekVersion
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case method
        case kdf = "kdf_alg"
        case opsLimit = "ops_limit"
        case memLimitBytes = "mem_limit_bytes"
        case salt
        case wrappedDEK = "wrapped_dek"
        case dekVersion = "dek_version"
        case updatedAt = "updated_at"
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        DatabaseTimestamp.encodingStrategy
    }

    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        DatabaseTimestamp.decodingStrategy
    }
}
