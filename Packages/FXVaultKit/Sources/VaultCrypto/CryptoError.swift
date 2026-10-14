/// Failures of the low-level primitives in VaultCrypto (§4.4). Carries no localized text and never
/// any key or plaintext material.
///
/// Vault-level outcomes (wrong password, invalid recovery key, corruption) are reported as
/// `VaultError` by ``KeyWrap`` and ``UnlockedKeys``. Callers that open field blobs map
/// ``authenticationFailed`` and ``malformedCiphertext`` to `VaultError.corrupted(.fieldDecryptionFailed)`
/// and ``unsupportedFormat(_:)`` to `.corrupted(.unsupportedFormatVersion)`.
public enum CryptoError: Error, Sendable, Hashable {
    /// libsodium could not be initialized.
    case sodiumUnavailable
    /// Argon2id inputs are outside libsodium's own limits (ops, memory, salt or output size).
    case invalidKDFInput
    /// Argon2id failed at run time (for example the memory could not be allocated).
    case kdfFailed
    /// A key, salt or id has the wrong number of bytes.
    case invalidLength(expected: Int, actual: Int)
    /// A blob starts with a format byte this build does not understand.
    case unsupportedFormat(UInt8)
    /// A blob is too short or otherwise not a valid sealed box.
    case malformedCiphertext
    /// AES-GCM authentication failed: wrong key, or the ciphertext, nonce, tag or AAD changed.
    case authenticationFailed
    /// The platform AES-GCM implementation refused to seal.
    case sealFailed
}
