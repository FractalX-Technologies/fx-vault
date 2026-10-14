import CryptoKit
import Foundation
import VaultCore

/// Row-bound value fingerprints for change detection without decryption (§5.4, D11, D13):
/// `HMAC-SHA256(K_fp, LP(row_uuid 16B) ‖ value)`, stored in `value_fp` and `synced_fp`.
///
/// Binding the row id means equal values in different rows have unrelated fingerprints, so the
/// database does not reveal which items share a value. Stateless: the key is passed in for each
/// call (§4.3). App code normally goes through ``UnlockedKeys/fingerprint(_:rowID:)``.
public enum ValueFingerprinter {
    /// Fingerprint size in bytes.
    public static let byteCount = SHA256.byteCount

    /// The fingerprint of `value` in row `rowID`.
    public static func fingerprint(of value: SecretBytes, rowID: ConfigItemID, key: SymmetricKey) -> Data {
        var mac = HMAC<SHA256>(key: key)
        var prefix = AADBuilder()
        prefix.appendLengthPrefixed(rowID.bytes)
        mac.update(data: prefix.data)
        value.withUnsafeBytes { mac.update(data: $0) }
        return Data(mac.finalize())
    }

    /// True when `fingerprint` matches `value` in row `rowID` (constant-time comparison).
    public static func matches(
        _ fingerprint: Data,
        value: SecretBytes,
        rowID: ConfigItemID,
        key: SymmetricKey
    ) -> Bool {
        let actual = self.fingerprint(of: value, rowID: rowID, key: key)
        return actual.withUnsafeBytes { lhs in
            fingerprint.withUnsafeBytes { rhs in
                SecretBytes.constantTimeEquals(lhs, rhs)
            }
        }
    }
}
