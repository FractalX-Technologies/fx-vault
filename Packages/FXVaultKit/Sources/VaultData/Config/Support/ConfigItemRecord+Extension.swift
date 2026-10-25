import Foundation
import VaultCore
import VaultStore

/// Row transitions of drift resolutions (§7.7).
extension ConfigItemRecord {
    /// No value and no synced value: the secret is "value missing".
    mutating func clearValues() {
        valueCiphertext = nil
        valueFingerprint = nil
        syncedValueCiphertext = nil
        syncedFingerprint = nil
    }

    /// A pending add again: every synced column cleared.
    mutating func markUnsynced() {
        syncedName = nil
        syncedValueCiphertext = nil
        syncedFingerprint = nil
        remoteUpdatedAt = nil
        forcePush = false
        forcePushRequestedAt = nil
        verifyState = .verified
        preWriteUpdatedAt = nil
    }
}
