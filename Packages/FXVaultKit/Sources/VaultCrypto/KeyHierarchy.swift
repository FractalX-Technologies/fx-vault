import CryptoKit
import Foundation
import VaultCore

/// Derivations of the key hierarchy (§5.1). Keys derived here never leave the module except
/// inside ``UnlockedKeys``.
///
/// ```
/// K_field = HKDF-SHA256(DEK, salt: vault_id, info: "fxvault/v1/field-enc", 32)
/// K_fp    = HKDF-SHA256(DEK, salt: vault_id, info: "fxvault/v1/fingerprint", 32)
/// K_rec   = HKDF-SHA256(recoveryKey32, salt: vault_id, info: "fxvault/v1/kek/recovery", 32)
/// ```
public enum KeyHierarchy {
    /// A new random `vault_id` (``Limits/vaultIDBytes`` bytes, not secret).
    public static func generateVaultID() -> Data {
        SecureRandom.data(count: Limits.vaultIDBytes)
    }

    /// A new random Argon2id salt (``Limits/kdfSaltBytes`` bytes, not secret).
    public static func generateSalt() -> Data {
        SecureRandom.data(count: Limits.kdfSaltBytes)
    }

    /// A new random 256-bit DEK.
    static func generateDEK() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// `K_field`.
    static func fieldKey(dek: SymmetricKey, vaultID: Data) -> SymmetricKey {
        expand(dek, vaultID: vaultID, info: CryptoDomain.fieldEncryptionInfo)
    }

    /// `K_fp`.
    static func fingerprintKey(dek: SymmetricKey, vaultID: Data) -> SymmetricKey {
        expand(dek, vaultID: vaultID, info: CryptoDomain.fingerprintInfo)
    }

    /// `K_rec`, the key-encryption key of the recovery wrap.
    static func recoveryKEK(recoveryKey: RecoveryKey, vaultID: Data) -> SymmetricKey {
        recoveryKey.withUnsafeBytes { bytes in
            expand(SymmetricKey(data: bytes), vaultID: vaultID, info: CryptoDomain.recoveryKEKInfo)
        }
    }

    private static func expand(_ material: SymmetricKey, vaultID: Data, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: material,
            salt: vaultID,
            info: Data(info.utf8),
            outputByteCount: CryptoDomain.symmetricKeyBytes
        )
    }
}
