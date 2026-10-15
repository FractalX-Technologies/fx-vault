import Foundation
import VaultCore
import VaultCrypto
import VaultStore

extension VaultRecord {
    /// The key-check inputs of this row, for unwrapping and Touch ID (§5.1).
    ///
    /// - Throws: `.corrupted(.unsupportedFormatVersion)` when a newer build wrote the row,
    ///   `.corrupted(.missingVaultRecord)` for an impossible format or DEK version.
    func keyContext() throws(VaultError) -> VaultKeyContext {
        if formatVersion > VaultRecord.initialVersion {
            throw .corrupted(.unsupportedFormatVersion)
        }
        guard
            formatVersion == VaultRecord.initialVersion,
            let dekVersion = UInt32(exactly: dekVersion)
        else { throw .corrupted(.missingVaultRecord) }
        return VaultKeyContext(vaultID: vaultID, dekVersion: dekVersion, kcv: kcv)
    }

    /// True when this row describes `keys` (vault id, DEK version and key-check value).
    func describes(_ keys: borrowing UnlockedKeys) -> Bool {
        guard let context = try? keyContext() else { return false }
        return keys.matches(context)
    }

    /// Records a successful master-password check (unlock, re-authentication, password change)
    /// for the restart and 14-day rules (§5.5).
    mutating func recordPasswordCheck(at date: Date, bootSession: String?) {
        lastPasswordUnlockAt = date
        lastPasswordBootSession = bootSession
    }

    /// Stores `keys` as the current DEK (after a rotation).
    mutating func adopt(_ keys: borrowing UnlockedKeys) {
        dekVersion = Int(keys.dekVersion)
        kcv = keys.kcv
    }
}
