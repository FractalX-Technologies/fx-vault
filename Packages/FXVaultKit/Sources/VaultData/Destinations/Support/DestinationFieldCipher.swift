import CryptoKit
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
    static func setValue(_ value: SecretBytes, on record: inout DestinationItemRecord, keys: borrowing UnlockedKeys) throws(CryptoError) {
        record.valueCiphertext = try keys.seal(value, for: valueAAD(of: record))
        record.valueFingerprint = keys.fingerprint(value, rowID: record.id)
    }

    /// Re-seals the value after the row's name or kind changed (`old` is the row before).
    static func reseal(from old: DestinationItemRecord, to record: inout DestinationItemRecord, keys: borrowing UnlockedKeys) throws {
        guard let value = try openValue(of: old, keys: keys) else { return }
        defer { value.wipe() }
        record.valueCiphertext = try keys.seal(value, for: valueAAD(of: record))
    }

    /// What Supabase lists for `value`: its SHA-256 as lowercase hex. Kept in memory only.
    static func supabaseDigest(of value: SecretBytes) -> String {
        value.withUnsafeBytes { bytes in
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The form of a Supabase change marker the vault compares and stores. Supabase lists an
    /// unkeyed SHA-256 of each value; stored as is, anyone holding the database file could test
    /// guesses of a weak value offline. The vault keeps the row-bound fingerprint under `K_fp`
    /// instead, with the destination's id in the row's place, over `<remote name>:<digest>`:
    /// equal listings still give equal markers. A DEK rotation re-keys the markers it can
    /// recompute from a synced value (`DEKRotator`).
    static func keyedMarker(digest: String, remoteName: String, destinationID: DestinationID, keys: borrowing UnlockedKeys) -> String {
        let input = SecretBytes(utf8: "\(remoteName):\(digest)")
        defer { input.wipe() }
        let mac = keys.fingerprint(input, rowID: ConfigItemID(destinationID.uuid))
        return markerPrefix + mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Marks a keyed marker in `remote_version`, `pre_write_version` and the journal.
    static let markerPrefix = "k1:"
}

/// Field encryption of `provider_connections.token_ct` (v0.8.0): a secret field bound to the
/// connection's id.
enum ConnectionTokenCipher {
    static let column = "token_ct"

    static func aad(of id: ConnectionID) -> SecretFieldAAD {
        SecretFieldAAD(table: ConnectionRecord.databaseTableName, column: column, rowKey: Data(id.bytes))
    }

    /// The decrypted token. The caller wipes it.
    static func openToken(of record: ConnectionRecord, keys: borrowing UnlockedKeys) throws(VaultError) -> SecretBytes {
        try keys.open(record.tokenCiphertext, for: aad(of: record.id))
    }

    static func seal(_ token: SecretBytes, for id: ConnectionID, keys: borrowing UnlockedKeys) throws(CryptoError) -> Data {
        try keys.seal(token, for: aad(of: id))
    }
}
