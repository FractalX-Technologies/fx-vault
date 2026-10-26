import Foundation
import VaultCore
import VaultCrypto
import VaultStore

/// Field encryption of `destination_items` rows (v0.8.0): the value is bound to the row,
/// destination, kind and name (`DestinationFieldAAD`), so a rename or a kind change re-seals it.
enum DestinationFieldCipher {
    static func valueAAD(of record: DestinationItemRecord) -> DestinationFieldAAD {
        DestinationFieldAAD(rowID: record.id, destinationID: record.destinationID, kind: record.kind, name: record.name)
    }

    /// Decrypts the value, or nil when the value is missing locally. The caller wipes the result.
    static func openValue(of record: DestinationItemRecord, keys: borrowing UnlockedKeys) throws(VaultError) -> SecretBytes? {
        guard let ciphertext = record.valueCiphertext else { return nil }
        return try keys.open(ciphertext, for: valueAAD(of: record))
    }

    /// Stores `value` sealed under the row's current identity, with its row-bound fingerprint.
    /// Another value drops the file label (v21); a re-seal for a rename keeps it.
    static func setValue(_ value: SecretBytes, on record: inout DestinationItemRecord, keys: borrowing UnlockedKeys) throws(CryptoError) {
        record.valueCiphertext = try keys.seal(value, for: valueAAD(of: record))
        let fingerprint = keys.fingerprint(value, rowID: record.id)
        if fingerprint != record.valueFingerprint {
            record.file = nil
        }
        record.valueFingerprint = fingerprint
    }

    /// Re-seals the value after the row's name or kind changed (`old` is the row before).
    static func reseal(from old: DestinationItemRecord, to record: inout DestinationItemRecord, keys: borrowing UnlockedKeys) throws {
        guard let value = try openValue(of: old, keys: keys) else { return }
        defer { value.wipe() }
        record.valueCiphertext = try keys.seal(value, for: valueAAD(of: record))
    }
}
