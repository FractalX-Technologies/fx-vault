import Foundation
import VaultCore
import VaultCrypto
import VaultStore

/// Field encryption of `config_items` rows (§5.4): the AAD of each encrypted column and the
/// seal/open steps every Config, Catalog and EnvFiles write uses.
///
/// The AAD binds the row id, repository, environment, kind and the column's name (`name` for
/// `value_ct`, `synced_name` for `synced_value_ct`), so a row whose name, scope or kind changes
/// must be re-sealed.
enum ConfigFieldCipher {
    /// The AAD of `value_ct` (bound to `name`).
    static func valueAAD(of record: ConfigItemRecord) -> FieldAAD {
        FieldAAD(
            location: .configItemValue,
            rowID: record.id,
            repositoryID: record.repositoryID,
            environmentID: record.environmentID,
            kind: record.kind,
            name: record.name
        )
    }

    /// The AAD of `synced_value_ct` (bound to `synced_name`), or nil when never synced.
    static func syncedAAD(of record: ConfigItemRecord) -> FieldAAD? {
        guard let syncedName = record.syncedName else { return nil }
        return FieldAAD(
            location: .configItemSyncedValue,
            rowID: record.id,
            repositoryID: record.repositoryID,
            environmentID: record.environmentID,
            kind: record.kind,
            name: syncedName
        )
    }

    /// Decrypts `value_ct`, or nil when the value is missing. The caller wipes the result.
    static func openValue(of record: ConfigItemRecord, keys: borrowing UnlockedKeys) throws(VaultError) -> SecretBytes? {
        guard let ciphertext = record.valueCiphertext else { return nil }
        return try keys.open(ciphertext, for: valueAAD(of: record))
    }

    /// Decrypts `synced_value_ct`, or nil when there is none. The caller wipes the result.
    static func openSyncedValue(of record: ConfigItemRecord, keys: borrowing UnlockedKeys) throws(VaultError)
        -> SecretBytes?
    {
        guard let ciphertext = record.syncedValueCiphertext, let aad = syncedAAD(of: record) else { return nil }
        return try keys.open(ciphertext, for: aad)
    }

    /// Stores `value` as the row's local value: `value_ct` sealed under the row's current
    /// identity and `value_fp` computed for its id.
    static func setValue(_ value: SecretBytes, on record: inout ConfigItemRecord, keys: borrowing UnlockedKeys) throws(CryptoError) {
        record.valueCiphertext = try keys.seal(value, for: valueAAD(of: record))
        record.valueFingerprint = keys.fingerprint(value, rowID: record.id)
    }

    /// Stores `value` as the row's synced value (`synced_value_ct`, `synced_fp`). The record
    /// must have a `synced_name`.
    static func setSyncedValue(
        _ value: SecretBytes,
        on record: inout ConfigItemRecord,
        keys: borrowing UnlockedKeys
    ) throws(CryptoError) {
        guard let aad = syncedAAD(of: record) else { return }
        record.syncedValueCiphertext = try keys.seal(value, for: aad)
        record.syncedFingerprint = keys.fingerprint(value, rowID: record.id)
    }
}
