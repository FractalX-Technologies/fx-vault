import CryptoKit
import Foundation
import VaultCore

/// AES-256-GCM encryption of one database field (§5.4).
///
/// Blob layout: `0x01 ‖ nonce(12) ‖ ciphertext ‖ tag(16)`, the format byte followed by CryptoKit's
/// `SealedBox.combined`. The AAD (``FieldAAD/encoded(dekVersion:)``) binds the blob to its row,
/// column, scope, kind and name. Stateless: the key is passed in for each call and never stored
/// (§4.3). App code normally goes through ``UnlockedKeys/seal(_:for:)`` and
/// ``UnlockedKeys/open(_:for:)``.
public enum FieldCipher {
    /// Format byte of version-1 blobs.
    public static let formatVersion = CryptoDomain.formatVersion1
    /// Smallest valid blob: format byte, nonce and tag around an empty ciphertext.
    public static let minimumBlobBytes = 1 + Limits.gcmNonceBytes + Limits.gcmTagBytes

    /// Encrypts `plaintext` under `key` with a fresh random nonce.
    public static func seal(_ plaintext: SecretBytes, key: SymmetricKey, aad: Data) throws(CryptoError) -> Data {
        try seal(plaintext, key: key, aad: aad, nonce: AES.GCM.Nonce())
    }

    /// Decrypts a blob made by ``seal(_:key:aad:)``. The caller wipes the result.
    ///
    /// - Throws: ``CryptoError/unsupportedFormat(_:)`` for an unknown format byte,
    ///   ``CryptoError/malformedCiphertext`` for a truncated blob, and
    ///   ``CryptoError/authenticationFailed`` for a wrong key or any change to the nonce,
    ///   ciphertext, tag or AAD.
    public static func open(_ blob: Data, key: SymmetricKey, aad: Data) throws(CryptoError) -> SecretBytes {
        guard let format = blob.first else { throw .malformedCiphertext }
        guard format == formatVersion else { throw .unsupportedFormat(format) }
        guard blob.count >= minimumBlobBytes else { throw .malformedCiphertext }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: blob.dropFirst())
        } catch {
            throw .malformedCiphertext
        }
        var plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw .authenticationFailed
        }
        return SecretBytes(wipingSource: &plaintext)
    }

    /// Seals with an explicit nonce. Internal so known-answer tests can fix the nonce; production
    /// code always uses a random one.
    static func seal(
        _ plaintext: SecretBytes,
        key: SymmetricKey,
        aad: Data,
        nonce: AES.GCM.Nonce
    ) throws(CryptoError) -> Data {
        let combined = plaintext.withUnsafeBytes { bytes in
            try? AES.GCM.seal(bytes, using: key, nonce: nonce, authenticating: aad).combined
        }
        guard let combined else { throw .sealFailed }
        var blob = Data(capacity: 1 + combined.count)
        blob.append(formatVersion)
        blob.append(combined)
        return blob
    }
}
