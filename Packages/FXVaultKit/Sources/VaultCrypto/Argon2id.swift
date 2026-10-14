import Clibsodium
import CryptoKit
import Foundation
import VaultCore

/// Derives a 256-bit key from a passphrase with a password-hashing KDF.
///
/// The seam for the master-password wrap (``KeyWrap``) and, through VaultData, for the
/// `.fxvault` codec in SharingKit (§9.1). Tests inject a fast fake or a spy (§12.2).
/// Implementations must not keep the passphrase.
public protocol PasswordKeyDeriving: Sendable {
    /// Derives ``CryptoDomain/symmetricKeyBytes`` bytes from `passphrase` (already normalized by the
    /// caller) and `salt`, with `opsLimit` passes over `memLimitBytes` bytes of memory.
    func deriveKey(passphrase: SecretBytes, salt: Data, opsLimit: UInt32, memLimitBytes: UInt64) throws -> SymmetricKey
}

/// Argon2id v1.3 (libsodium `crypto_pwhash`, `ALG_ARGON2ID13`, parallelism 1), §5.1 `K_pw`.
///
/// This is the only file in the project that imports Clibsodium (§4.2). Buffers owned by this
/// code are zeroed with `sodium_memzero` before they are released; libsodium wipes its own
/// working memory.
///
/// Policy bounds (``KDFBounds``) are the caller's job and must run before this. This type only
/// enforces libsodium's absolute limits.
public enum Argon2id {
    /// NFC-normalizes `password` and copies its UTF-8 bytes into a wipeable buffer (D8).
    ///
    /// Composed and decomposed spellings of the same text (`ó` vs `o` + U+0301) therefore derive
    /// the same key. The caller wipes the result.
    public static func normalizedPassword(_ password: String) -> SecretBytes {
        SecretBytes(utf8: password.precomposedStringWithCanonicalMapping)
    }

    /// Derives a 32-byte key from `password` bytes (use ``normalizedPassword(_:)`` for user input).
    ///
    /// - Throws: ``CryptoError/invalidKDFInput`` when the salt is not
    ///   ``Limits/kdfSaltBytes`` long or the parameters are outside libsodium's limits;
    ///   ``CryptoError/kdfFailed`` when libsodium fails (for example out of memory);
    ///   ``CryptoError/sodiumUnavailable`` when libsodium cannot be initialized.
    public static func deriveKey(
        password: SecretBytes,
        salt: Data,
        parameters: KDFParameters
    ) throws(CryptoError) -> SymmetricKey {
        let output = SecretBytes(count: CryptoDomain.symmetricKeyBytes)
        defer { output.wipe() }
        try derive(into: output, password: password, salt: salt, parameters: parameters)
        return output.withUnsafeMutableBytes { bytes in
            let key = SymmetricKey(data: UnsafeRawBufferPointer(bytes))
            if let base = bytes.baseAddress {
                sodium_memzero(base, bytes.count)
            }
            return key
        }
    }

    // MARK: - Private

    /// Whether `sodium_init()` succeeded. Evaluated once, thread-safely, on first use
    /// (`sodium_init` returns 1 when it was already initialized, -1 on failure).
    private static let isSodiumReady: Bool = sodium_init() >= 0

    private static func derive(
        into output: SecretBytes,
        password: SecretBytes,
        salt: Data,
        parameters: KDFParameters
    ) throws(CryptoError) {
        guard isSodiumReady else { throw .sodiumUnavailable }
        guard
            salt.count == crypto_pwhash_saltbytes(),
            salt.count == Limits.kdfSaltBytes,
            let memLimit = Int(exactly: parameters.memLimitBytes),
            memLimit >= crypto_pwhash_memlimit_min(),
            memLimit <= crypto_pwhash_memlimit_max(),
            Int(parameters.opsLimit) >= crypto_pwhash_opslimit_min(),
            Int(parameters.opsLimit) <= crypto_pwhash_opslimit_max(),
            output.count >= crypto_pwhash_bytes_min()
        else { throw .invalidKDFInput }

        let status: Int32 = output.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pass in
                salt.withUnsafeBytes { saltBytes in
                    call(out: out, password: pass, salt: saltBytes, opsLimit: parameters.opsLimit, memLimit: memLimit)
                }
            }
        }
        guard status == 0 else { throw .kdfFailed }
    }

    /// The raw libsodium call. Returns libsodium's status (0 on success). On failure the output
    /// buffer is zeroed so no partial key survives.
    private static func call(
        out: UnsafeMutableRawBufferPointer,
        password: UnsafeRawBufferPointer,
        salt: UnsafeRawBufferPointer,
        opsLimit: UInt32,
        memLimit: Int
    ) -> Int32 {
        guard
            let outBase = out.baseAddress?.assumingMemoryBound(to: UInt8.self),
            let saltBase = salt.baseAddress?.assumingMemoryBound(to: UInt8.self)
        else { return -1 }
        // libsodium requires a non-null password pointer even for an empty password.
        var emptyPassword: CChar = 0
        let status = withUnsafeMutablePointer(to: &emptyPassword) { emptyPointer in
            let passBase = password.baseAddress?.assumingMemoryBound(to: CChar.self) ?? UnsafePointer(emptyPointer)
            return crypto_pwhash(
                outBase,
                UInt64(out.count),
                passBase,
                UInt64(password.count),
                saltBase,
                UInt64(opsLimit),
                memLimit,
                crypto_pwhash_alg_argon2id13()
            )
        }
        if status != 0 {
            sodium_memzero(outBase, out.count)
        }
        return status
    }
}

/// ``PasswordKeyDeriving`` backed by ``Argon2id``.
///
/// Inject this into ``KeyWrap`` (master password) and, through VaultData, into SharingKit's
/// `.fxvault` codec (convert the header's KiB to bytes first). It does not normalize the
/// passphrase: pass ``Argon2id/normalizedPassword(_:)`` or an already canonical form.
public struct Argon2idKeyDeriver: PasswordKeyDeriving {
    public init() {}

    public func deriveKey(
        passphrase: SecretBytes,
        salt: Data,
        opsLimit: UInt32,
        memLimitBytes: UInt64
    ) throws -> SymmetricKey {
        try Argon2id.deriveKey(
            password: passphrase,
            salt: salt,
            parameters: KDFParameters(opsLimit: opsLimit, memLimitBytes: memLimitBytes)
        )
    }
}
