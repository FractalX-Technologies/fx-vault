import Foundation
import VaultCore
import VaultStore

/// Row transitions shared by drift resolutions (§7.7) and teammates' versions (v0.6.0, S8).
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
