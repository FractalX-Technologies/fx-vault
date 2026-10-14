import CryptoKit
import Foundation
import VaultCore

/// The unlock method of a `key_wraps` row (§6). Raw values match the `method` CHECK constraint.
public enum KeyWrapMethod: String, Sendable, Hashable, CaseIterable {
    /// Argon2id over the master password.
    case password
    /// HKDF over the recovery key.
    case recovery

    /// The only KDF accepted for this method.
    public var kdfAlgorithm: KDFAlgorithm {
        switch self {
        case .password: .argon2id13
        case .recovery: .hkdfSHA256
        }
    }
}

/// One `key_wraps` row: the DEK wrapped under a key-encryption key (§5.2).
public struct KeyWrapModel: Sendable, Hashable {
    public let method: KeyWrapMethod
    public let kdfAlgorithm: KDFAlgorithm
    /// Argon2id parameters; nil for ``KeyWrapMethod/recovery``.
    public let kdfParameters: KDFParameters?
    /// Argon2id salt; nil for ``KeyWrapMethod/recovery``.
    public let salt: Data?
    /// The 62-byte wrap (``KeyWrap/wrappedDEKBytes``).
    public let wrappedDEK: Data
    public let dekVersion: UInt32

    public init(
        method: KeyWrapMethod,
        kdfAlgorithm: KDFAlgorithm,
        kdfParameters: KDFParameters?,
        salt: Data?,
        wrappedDEK: Data,
        dekVersion: UInt32
    ) {
        self.method = method
        self.kdfAlgorithm = kdfAlgorithm
        self.kdfParameters = kdfParameters
        self.salt = salt
        self.wrappedDEK = wrappedDEK
        self.dekVersion = dekVersion
    }

    /// Builds a wrap from its database columns, rejecting values no build ever writes.
    ///
    /// - Throws: `.corrupted(.invalidWrapFormat)` for an unknown method or a DEK version outside
    ///   `UInt32`; `.corrupted(.kdfParametersOutOfBounds)` for an unknown `kdf_alg`, negative or
    ///   oversized limits, or only one of the two limits present.
    public init(
        storedMethod: String,
        kdfAlgorithm storedAlgorithm: Int64,
        opsLimit: Int64?,
        memLimitBytes: Int64?,
        salt: Data?,
        wrappedDEK: Data,
        dekVersion storedDEKVersion: Int64
    ) throws(VaultError) {
        guard
            let method = KeyWrapMethod(rawValue: storedMethod),
            let dekVersion = UInt32(exactly: storedDEKVersion)
        else { throw .corrupted(.invalidWrapFormat) }
        guard
            let rawAlgorithm = UInt8(exactly: storedAlgorithm),
            let algorithm = KDFAlgorithm(rawValue: rawAlgorithm)
        else { throw .corrupted(.kdfParametersOutOfBounds) }

        let parameters: KDFParameters?
        switch (opsLimit, memLimitBytes) {
        case (nil, nil):
            parameters = nil
        case let (ops?, mem?):
            guard let ops = UInt32(exactly: ops), let mem = UInt64(exactly: mem) else {
                throw .corrupted(.kdfParametersOutOfBounds)
            }
            parameters = KDFParameters(opsLimit: ops, memLimitBytes: mem)
        default:
            throw .corrupted(.kdfParametersOutOfBounds)
        }
        self.init(
            method: method,
            kdfAlgorithm: algorithm,
            kdfParameters: parameters,
            salt: salt,
            wrappedDEK: wrappedDEK,
            dekVersion: dekVersion
        )
    }

    /// `key_wraps.kdf_alg`.
    public var storedKDFAlgorithm: Int64 {
        Int64(kdfAlgorithm.rawValue)
    }

    /// `key_wraps.ops_limit` (NULL for recovery).
    public var storedOpsLimit: Int64? {
        kdfParameters.map { Int64($0.opsLimit) }
    }

    /// `key_wraps.mem_limit_bytes` (NULL for recovery).
    public var storedMemLimitBytes: Int64? {
        kdfParameters.flatMap { Int64(exactly: $0.memLimitBytes) }
    }

    /// `key_wraps.dek_version`.
    public var storedDEKVersion: Int64 {
        Int64(dekVersion)
    }
}

/// Wraps and unwraps the DEK (§5.2).
///
/// ```
/// wrapped_dek (62 B) = [0] format=0x01 [1] aead=0x01 [2..13] nonce [14..45] ct(DEK) [46..61] tag
/// AAD = u8(format) ‖ u8(aead) ‖ LP("fxvault/v1/dek-wrap") ‖ LP(method) ‖ LP(vault_id)
///       ‖ u32be(dek_version) ‖ u8(kdf_alg) ‖ u32be(ops|0) ‖ u64be(mem_bytes|0) ‖ LP(salt|empty)
/// ```
///
/// Unwrapping checks the stored format, method, DEK version and KDF parameters **before** any
/// KDF runs, then opens the wrap, then verifies the key-check value. Errors are `VaultError`:
/// a GCM failure is `.wrongPassword` / `.invalidRecoveryKey`, everything else `.corrupted`.
/// A KDF failure (for example out of memory) propagates as ``CryptoError``.
public enum KeyWrap {
    /// Size of `key_wraps.wrapped_dek`.
    public static let wrappedDEKBytes = Limits.wrappedDEKBytes

    // MARK: - Password

    /// Wraps `keys`' DEK under Argon2id(`password`) with a fresh salt and nonce.
    ///
    /// The password is NFC-normalized (D8). Use the same `policy` for every wrap of a vault.
    public static func wrap(
        _ keys: borrowing UnlockedKeys,
        password: String,
        policy: KDFPolicy,
        deriver: some PasswordKeyDeriving = Argon2idKeyDeriver()
    ) throws -> KeyWrapModel {
        let salt = KeyHierarchy.generateSalt()
        let kek = try deriveKEK(password: password, salt: salt, parameters: policy.parameters, deriver: deriver)
        return try wrap(
            keys,
            method: .password,
            kdfParameters: policy.parameters,
            salt: salt,
            kek: kek,
            nonce: AES.GCM.Nonce()
        )
    }

    /// Unwraps the password wrap and verifies the result against the vault row.
    ///
    /// - Throws: `.wrongPassword` when the wrap does not open; `.corrupted(...)` for a malformed
    ///   wrap, out-of-bounds KDF parameters (before the KDF runs), a DEK version that differs from
    ///   the vault row, or a key-check mismatch; ``CryptoError`` when the KDF itself fails.
    public static func unwrap(
        _ wrap: KeyWrapModel,
        password: String,
        context: VaultKeyContext,
        policy: KDFPolicy,
        deriver: some PasswordKeyDeriving = Argon2idKeyDeriver()
    ) throws -> UnlockedKeys {
        try validateStructure(wrap, method: .password, context: context)
        guard
            let parameters = wrap.kdfParameters,
            let salt = wrap.salt,
            policy.bounds.contains(parameters, saltCount: salt.count)
        else { throw VaultError.corrupted(.kdfParametersOutOfBounds) }

        let kek = try deriveKEK(password: password, salt: salt, parameters: parameters, deriver: deriver)
        return try open(wrap, kek: kek, context: context, failure: .wrongPassword)
    }

    // MARK: - Recovery key

    /// Wraps `keys`' DEK under `K_rec` = HKDF(`recoveryKey`, vault_id) with a fresh nonce.
    public static func wrap(_ keys: borrowing UnlockedKeys, recoveryKey: RecoveryKey) throws(CryptoError) -> KeyWrapModel {
        try wrap(keys, recoveryKey: recoveryKey, nonce: AES.GCM.Nonce())
    }

    /// Unwraps the recovery wrap and verifies the result against the vault row.
    ///
    /// - Throws: `.invalidRecoveryKey` when the wrap does not open; `.corrupted(...)` as for the
    ///   password wrap.
    public static func unwrap(
        _ wrap: KeyWrapModel,
        recoveryKey: RecoveryKey,
        context: VaultKeyContext
    ) throws(VaultError) -> UnlockedKeys {
        try validateStructure(wrap, method: .recovery, context: context)
        guard wrap.kdfParameters == nil, wrap.salt == nil else { throw .corrupted(.kdfParametersOutOfBounds) }
        let kek = KeyHierarchy.recoveryKEK(recoveryKey: recoveryKey, vaultID: context.vaultID)
        return try open(wrap, kek: kek, context: context, failure: .invalidRecoveryKey)
    }

    // MARK: - Internal (fixed nonces for known-answer tests)

    static func wrap(
        _ keys: borrowing UnlockedKeys,
        recoveryKey: RecoveryKey,
        nonce: AES.GCM.Nonce
    ) throws(CryptoError) -> KeyWrapModel {
        let kek = KeyHierarchy.recoveryKEK(recoveryKey: recoveryKey, vaultID: keys.vaultID)
        return try wrap(keys, method: .recovery, kdfParameters: nil, salt: nil, kek: kek, nonce: nonce)
    }

    static func wrap(
        _ keys: borrowing UnlockedKeys,
        method: KeyWrapMethod,
        kdfParameters: KDFParameters?,
        salt: Data?,
        kek: SymmetricKey,
        nonce: AES.GCM.Nonce
    ) throws(CryptoError) -> KeyWrapModel {
        let aad = additionalData(
            method: method,
            vaultID: keys.vaultID,
            dekVersion: keys.dekVersion,
            kdfParameters: kdfParameters,
            salt: salt
        )
        let combined = keys.material.dek.withUnsafeBytes { dek in
            try? AES.GCM.seal(dek, using: kek, nonce: nonce, authenticating: aad).combined
        }
        guard let combined else { throw .sealFailed }
        var wrapped = Data([CryptoDomain.formatVersion1, CryptoDomain.aeadAES256GCM])
        wrapped.append(combined)
        guard wrapped.count == wrappedDEKBytes else { throw .sealFailed }
        return KeyWrapModel(
            method: method,
            kdfAlgorithm: method.kdfAlgorithm,
            kdfParameters: kdfParameters,
            salt: salt,
            wrappedDEK: wrapped,
            dekVersion: keys.dekVersion
        )
    }

    /// The wrap AAD (§5.2). Absent KDF parameters encode as zero and an absent salt as an empty
    /// field. The format and AEAD bytes are always the version-1 values.
    static func additionalData(
        method: KeyWrapMethod,
        vaultID: Data,
        dekVersion: UInt32,
        kdfParameters: KDFParameters?,
        salt: Data?
    ) -> Data {
        var builder = AADBuilder()
        builder.append(CryptoDomain.formatVersion1)
        builder.append(CryptoDomain.aeadAES256GCM)
        builder.appendLengthPrefixed(CryptoDomain.dekWrapLabel)
        builder.appendLengthPrefixed(method.rawValue)
        builder.appendLengthPrefixed(vaultID)
        builder.append(uint32BigEndian: dekVersion)
        builder.append(method.kdfAlgorithm.rawValue)
        builder.append(uint32BigEndian: kdfParameters?.opsLimit ?? 0)
        builder.append(uint64BigEndian: kdfParameters?.memLimitBytes ?? 0)
        builder.appendLengthPrefixed(salt ?? Data())
        return builder.data
    }

    // MARK: - Private

    private static let formatByteIndex = 0
    private static let aeadByteIndex = 1
    private static let headerBytes = 2

    /// Every check that does not need a key: context, method, KDF algorithm, layout, version.
    private static func validateStructure(
        _ wrap: KeyWrapModel,
        method: KeyWrapMethod,
        context: VaultKeyContext
    ) throws(VaultError) {
        try context.validate()
        guard wrap.method == method else { throw .corrupted(.missingKeyWrap) }
        guard wrap.kdfAlgorithm == method.kdfAlgorithm else { throw .corrupted(.kdfParametersOutOfBounds) }
        let bytes = wrap.wrappedDEK
        guard bytes.count == wrappedDEKBytes else { throw .corrupted(.invalidWrapFormat) }
        let format = bytes[bytes.startIndex + formatByteIndex]
        if format > CryptoDomain.formatVersion1 { throw .corrupted(.unsupportedFormatVersion) }
        guard
            format == CryptoDomain.formatVersion1,
            bytes[bytes.startIndex + aeadByteIndex] == CryptoDomain.aeadAES256GCM
        else { throw .corrupted(.invalidWrapFormat) }
        guard wrap.dekVersion == context.dekVersion else { throw .corrupted(.invalidWrapFormat) }
    }

    private static func deriveKEK(
        password: String,
        salt: Data,
        parameters: KDFParameters,
        deriver: some PasswordKeyDeriving
    ) throws -> SymmetricKey {
        let normalized = Argon2id.normalizedPassword(password)
        defer { normalized.wipe() }
        return try deriver.deriveKey(
            passphrase: normalized,
            salt: salt,
            opsLimit: parameters.opsLimit,
            memLimitBytes: parameters.memLimitBytes
        )
    }

    /// Opens a structurally valid wrap, then checks the DEK against the vault's kcv.
    private static func open(
        _ wrap: KeyWrapModel,
        kek: SymmetricKey,
        context: VaultKeyContext,
        failure: VaultError
    ) throws(VaultError) -> UnlockedKeys {
        let aad = additionalData(
            method: wrap.method,
            vaultID: context.vaultID,
            dekVersion: wrap.dekVersion,
            kdfParameters: wrap.kdfParameters,
            salt: wrap.salt
        )
        var dekData: Data
        do {
            let box = try AES.GCM.SealedBox(combined: wrap.wrappedDEK.dropFirst(headerBytes))
            dekData = try AES.GCM.open(box, using: kek, authenticating: aad)
        } catch {
            throw failure
        }
        let dekBytes = SecretBytes(wipingSource: &dekData)
        defer { dekBytes.wipe() }
        return try UnlockedKeys(dekBytes: dekBytes, context: context)
    }
}
