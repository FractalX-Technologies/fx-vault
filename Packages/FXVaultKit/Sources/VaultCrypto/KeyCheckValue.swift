import CryptoKit
import Foundation
import VaultCore

/// The key-check value stored in `vaults.kcv` (§5.1):
/// `HMAC-SHA256(DEK, "fxvault/v1/kcv")[0..<16]`.
///
/// Checked in constant time after every unwrap and every Touch ID read, so a DEK that unwraps
/// cleanly but belongs to another vault (or a swapped keychain item) is rejected.
enum KeyCheckValue {
    /// The 16-byte key-check value of `dek`.
    static func compute(for dek: SymmetricKey) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(CryptoDomain.keyCheckLabel.utf8), using: dek)
        return Data(mac.prefix(Limits.kcvBytes))
    }

    /// True when `expected` is the key-check value of `dek` (constant-time comparison).
    static func matches(_ dek: SymmetricKey, expected: Data) -> Bool {
        let actual = compute(for: dek)
        return actual.withUnsafeBytes { lhs in
            expected.withUnsafeBytes { rhs in
                SecretBytes.constantTimeEquals(lhs, rhs)
            }
        }
    }
}
