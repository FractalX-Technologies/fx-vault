import Foundation
import VaultCore
import VaultCrypto
import VaultStore

/// Field encryption of `folder_items` rows (v0.7.0): the value is bound to the row, folder, kind
/// and name (`FolderFieldAAD`), so a rename or a kind change re-seals it.
enum FolderFieldCipher {
    static func valueAAD(of record: FolderItemRecord) -> FolderFieldAAD {
        FolderFieldAAD(rowID: record.id, folderID: record.folderID, kind: record.kind, name: record.name)
    }

    /// Decrypts the value. The caller wipes the result.
    static func openValue(of record: FolderItemRecord, keys: borrowing UnlockedKeys) throws(VaultError) -> SecretBytes {
        try keys.open(record.valueCiphertext, for: valueAAD(of: record))
    }

    /// Stores `value` sealed under the row's current identity, with its row-bound fingerprint.
    static func setValue(_ value: SecretBytes, on record: inout FolderItemRecord, keys: borrowing UnlockedKeys) throws(CryptoError) {
        record.valueCiphertext = try keys.seal(value, for: valueAAD(of: record))
        record.valueFingerprint = keys.fingerprint(value, rowID: record.id)
    }
}
