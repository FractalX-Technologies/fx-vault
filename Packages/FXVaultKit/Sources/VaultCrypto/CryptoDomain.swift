import Foundation

/// Domain-separation labels and fixed format bytes of the vault's cryptography (§5.1-§5.4).
///
/// Every label is versioned (`fxvault/v1/...`). Changing any of them makes existing vaults
/// unreadable, so they are frozen; a new format gets new labels.
public enum CryptoDomain {
    /// HKDF info for the field-encryption key `K_field` (§5.1).
    public static let fieldEncryptionInfo = "fxvault/v1/field-enc"
    /// HKDF info for the fingerprint key `K_fp` (§5.1).
    public static let fingerprintInfo = "fxvault/v1/fingerprint"
    /// HMAC message of the key-check value (§5.1).
    public static let keyCheckLabel = "fxvault/v1/kcv"
    /// HKDF info for the recovery key-encryption key `K_rec` (§5.1).
    public static let recoveryKEKInfo = "fxvault/v1/kek/recovery"
    /// SHA-256 prefix of the recovery key checksum (§5.3).
    public static let recoveryCheckLabel = "fxvault/v1/recovery-check"
    /// First field of every DEK-wrap AAD (§5.2).
    public static let dekWrapLabel = "fxvault/v1/dek-wrap"
    /// First field of every field-encryption AAD (§5.4).
    public static let fieldLabel = "fxvault/v1/field"
    /// First field of every secret-field AAD (v0.5.0: teammate keys; v0.6.0: space keys).
    public static let secretFieldLabel = "fxvault/v1/secret-field"

    /// Format byte of field blobs and DEK wraps, version 1.
    public static let formatVersion1: UInt8 = 0x01
    /// AEAD identifier of AES-256-GCM in DEK wraps.
    public static let aeadAES256GCM: UInt8 = 0x01

    /// Bytes of a 256-bit symmetric key (DEK, `K_field`, `K_fp`, KEKs).
    public static let symmetricKeyBytes = 32
}
