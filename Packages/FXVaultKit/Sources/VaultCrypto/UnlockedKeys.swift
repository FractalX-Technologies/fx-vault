import CryptoKit
import Foundation
import VaultCore

/// The key-check inputs of the single `vaults` row (§6): what every unwrap is verified against.
public struct VaultKeyContext: Sendable, Hashable {
    /// `vaults.vault_id` (``Limits/vaultIDBytes`` bytes).
    public let vaultID: Data
    /// `vaults.dek_version`.
    public let dekVersion: UInt32
    /// `vaults.kcv` (``Limits/kcvBytes`` bytes).
    public let kcv: Data

    public init(vaultID: Data, dekVersion: UInt32, kcv: Data) {
        self.vaultID = vaultID
        self.dekVersion = dekVersion
        self.kcv = kcv
    }

    /// Throws `.corrupted(.missingVaultRecord)` when the stored ids have the wrong size.
    func validate() throws(VaultError) {
        guard vaultID.count == Limits.vaultIDBytes, kcv.count == Limits.kcvBytes else {
            throw .corrupted(.missingVaultRecord)
        }
    }
}

/// The unlocked key set of one vault: the DEK plus the purpose keys derived from it (§5.1).
///
/// There are no public `SymmetricKey` accessors (§4.3). Everything the rest of the app needs is
/// a method here: field encryption, fingerprints, the key-check value, wrapping and the DEK
/// export for the Touch ID item. Values live in ``VaultKeyring`` while the vault is unlocked; code
/// reaches them through ``VaultKeyring/withKeys(_:)`` and must not keep them.
public struct UnlockedKeys: Sendable {
    /// Reference-typed storage so the keyring can prove the keys are released after `lock()`.
    final class Material: Sendable {
        let dek: SymmetricKey
        let fieldKey: SymmetricKey
        let fingerprintKey: SymmetricKey

        init(dek: SymmetricKey, vaultID: Data) {
            self.dek = dek
            fieldKey = KeyHierarchy.fieldKey(dek: dek, vaultID: vaultID)
            fingerprintKey = KeyHierarchy.fingerprintKey(dek: dek, vaultID: vaultID)
        }
    }

    let material: Material
    /// `vaults.vault_id`.
    public let vaultID: Data
    /// The DEK version bound into every field AAD and wrap AAD.
    public let dekVersion: UInt32
    /// The keyring generation these keys were read under (0 before installation). Pass it to
    /// ``VaultKeyring/ensureCurrent(_:)`` before committing work that used them.
    public internal(set) var generation: UInt64 = 0

    init(dek: SymmetricKey, vaultID: Data, dekVersion: UInt32) {
        material = Material(dek: dek, vaultID: vaultID)
        self.vaultID = vaultID
        self.dekVersion = dekVersion
    }

    // MARK: - Creating

    /// A fresh random DEK for a new vault (`dek_version` 1 by default).
    ///
    /// - Throws: ``CryptoError/invalidLength(expected:actual:)`` when `vaultID` is not
    ///   ``Limits/vaultIDBytes`` long.
    public static func generate(
        vaultID: Data,
        dekVersion: UInt32 = initialDEKVersion
    ) throws(CryptoError) -> UnlockedKeys {
        guard vaultID.count == Limits.vaultIDBytes else {
            throw .invalidLength(expected: Limits.vaultIDBytes, actual: vaultID.count)
        }
        return UnlockedKeys(dek: KeyHierarchy.generateDEK(), vaultID: vaultID, dekVersion: dekVersion)
    }

    /// Rebuilds the keys from raw DEK bytes (the Touch ID keychain item, §5.5) and verifies them
    /// against the vault row.
    ///
    /// - Throws: `.corrupted(.missingVaultRecord)` for a malformed context,
    ///   `.corrupted(.invalidStoredValue)` when `dekBytes` is not 32 bytes, and
    ///   `.corrupted(.keyCheckMismatch)` when the DEK does not match `vaults.kcv` (delete the item
    ///   and fall back to the password).
    public init(dekBytes: SecretBytes, context: VaultKeyContext) throws(VaultError) {
        try context.validate()
        guard dekBytes.count == CryptoDomain.symmetricKeyBytes else { throw .corrupted(.invalidStoredValue) }
        let dek = dekBytes.withUnsafeBytes { SymmetricKey(data: $0) }
        guard KeyCheckValue.matches(dek, expected: context.kcv) else { throw .corrupted(.keyCheckMismatch) }
        self.init(dek: dek, vaultID: context.vaultID, dekVersion: context.dekVersion)
    }

    /// A new random DEK for `rotateDEK` (§5.2): same vault, `dekVersion + 1`. The caller
    /// re-encrypts every field, recomputes fingerprints, re-wraps and stores the new ``kcv`` in one
    /// transaction before installing the result.
    public func rotated() -> UnlockedKeys {
        UnlockedKeys(dek: KeyHierarchy.generateDEK(), vaultID: vaultID, dekVersion: dekVersion + 1)
    }

    /// `dek_version` of a new vault.
    public static let initialDEKVersion: UInt32 = 1

    // MARK: - Vault row

    /// The key-check value to store in `vaults.kcv`.
    public var kcv: Data {
        KeyCheckValue.compute(for: material.dek)
    }

    /// The values to store in the `vaults` row for these keys.
    public var context: VaultKeyContext {
        VaultKeyContext(vaultID: vaultID, dekVersion: dekVersion, kcv: kcv)
    }

    /// True when these keys match `context` (vault id, DEK version and key-check value).
    public func matches(_ context: VaultKeyContext) -> Bool {
        context.vaultID == vaultID
            && context.dekVersion == dekVersion
            && KeyCheckValue.matches(material.dek, expected: context.kcv)
    }

    // MARK: - Fields (§5.4)

    /// Encrypts `value` for `field` under `K_field` and this DEK version.
    public func seal(_ value: SecretBytes, for field: FieldAAD) throws(CryptoError) -> Data {
        try FieldCipher.seal(value, key: material.fieldKey, aad: field.encoded(dekVersion: dekVersion))
    }

    /// Decrypts a field blob. The caller wipes the result.
    ///
    /// - Throws: `.corrupted(.unsupportedFormatVersion)` for an unknown format byte and
    ///   `.corrupted(.fieldDecryptionFailed)` for any other failure (tampered blob, kind or scope
    ///   flip, wrong row, other DEK version).
    public func open(_ blob: Data, for field: FieldAAD) throws(VaultError) -> SecretBytes {
        do {
            return try FieldCipher.open(blob, key: material.fieldKey, aad: field.encoded(dekVersion: dekVersion))
        } catch .unsupportedFormat(_) {
            throw .corrupted(.unsupportedFormatVersion)
        } catch {
            throw .corrupted(.fieldDecryptionFailed)
        }
    }

    /// Encrypts `value` for a secret field (v0.5.0) under `K_field` and this DEK version.
    public func seal(_ value: SecretBytes, for field: SecretFieldAAD) throws(CryptoError) -> Data {
        try FieldCipher.seal(value, key: material.fieldKey, aad: field.encoded(dekVersion: dekVersion))
    }

    /// Decrypts a secret-field blob. The caller wipes the result.
    ///
    /// - Throws: `.corrupted(.unsupportedFormatVersion)` or `.corrupted(.fieldDecryptionFailed)`.
    public func open(_ blob: Data, for field: SecretFieldAAD) throws(VaultError) -> SecretBytes {
        do {
            return try FieldCipher.open(blob, key: material.fieldKey, aad: field.encoded(dekVersion: dekVersion))
        } catch .unsupportedFormat(_) {
            throw .corrupted(.unsupportedFormatVersion)
        } catch {
            throw .corrupted(.fieldDecryptionFailed)
        }
    }

    /// Encrypts a folder item's value (v0.7.0) under `K_field` and this DEK version.
    public func seal(_ value: SecretBytes, for field: FolderFieldAAD) throws(CryptoError) -> Data {
        try FieldCipher.seal(value, key: material.fieldKey, aad: field.encoded(dekVersion: dekVersion))
    }

    /// Decrypts a folder item's value. The caller wipes the result.
    ///
    /// - Throws: `.corrupted(.unsupportedFormatVersion)` or `.corrupted(.fieldDecryptionFailed)`.
    public func open(_ blob: Data, for field: FolderFieldAAD) throws(VaultError) -> SecretBytes {
        do {
            return try FieldCipher.open(blob, key: material.fieldKey, aad: field.encoded(dekVersion: dekVersion))
        } catch .unsupportedFormat(_) {
            throw .corrupted(.unsupportedFormatVersion)
        } catch {
            throw .corrupted(.fieldDecryptionFailed)
        }
    }

    /// The row-bound fingerprint of `value` under `K_fp`.
    public func fingerprint(_ value: SecretBytes, rowID: ConfigItemID) -> Data {
        ValueFingerprinter.fingerprint(of: value, rowID: rowID, key: material.fingerprintKey)
    }

    /// True when `fingerprint` is the fingerprint of `value` in row `rowID` (constant time).
    public func fingerprintMatches(_ fingerprint: Data, value: SecretBytes, rowID: ConfigItemID) -> Bool {
        ValueFingerprinter.matches(fingerprint, value: value, rowID: rowID, key: material.fingerprintKey)
    }

    // MARK: - Touch ID (§5.5)

    /// A copy of the DEK bytes for the Touch ID keychain item. The caller wipes it right after
    /// `SecItemAdd`.
    public func exportDEK() -> SecretBytes {
        material.dek.withUnsafeBytes { SecretBytes(copying: $0) }
    }
}
