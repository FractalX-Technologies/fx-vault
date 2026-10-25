import Foundation
import VaultCore
import VaultCrypto
import VaultStore

/// Field encryption of `org_items` rows (1.0): the value is bound to the row, organization, kind
/// and name (`OrgFieldAAD`), so a rename or a kind change re-seals it.
enum OrgFieldCipher {
    static func valueAAD(of record: OrgItemRecord) -> OrgFieldAAD {
        OrgFieldAAD(rowID: record.id, organizationID: record.organizationID, kind: record.kind, name: record.name)
    }

    /// Decrypts the value, or nil for a secret with no value in the vault. The caller wipes the result.
    static func openValue(of record: OrgItemRecord, keys: borrowing UnlockedKeys) throws(VaultError) -> SecretBytes? {
        guard let ciphertext = record.valueCiphertext else { return nil }
        return try keys.open(ciphertext, for: valueAAD(of: record))
    }

    /// Stores `value` sealed under the row's current identity, with its row-bound fingerprint.
    static func setValue(_ value: SecretBytes, on record: inout OrgItemRecord, keys: borrowing UnlockedKeys) throws(CryptoError) {
        record.valueCiphertext = try keys.seal(value, for: valueAAD(of: record))
        record.valueFingerprint = keys.fingerprint(value, rowID: record.id)
    }
}
