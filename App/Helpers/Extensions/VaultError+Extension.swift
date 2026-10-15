import VaultCore

nonisolated extension VaultError {
    /// A short title for an alert or inline error.
    var localizedTitle: String {
        switch self {
        case .wrongPassword:
            String(localized: "error.vault.wrongPassword.title", defaultValue: "Incorrect password")
        case .invalidRecoveryKey:
            String(localized: "error.vault.invalidRecoveryKey.title", defaultValue: "Recovery key not accepted")
        case .locked:
            String(localized: "error.vault.locked.title", defaultValue: "FX Vault is locked")
        case .corrupted:
            String(localized: "error.vault.corrupted.title", defaultValue: "The vault failed an integrity check")
        case .biometryInvalidated:
            String(localized: "error.vault.biometryInvalidated.title", defaultValue: "Touch ID was turned off")
        case .biometryUnavailable:
            String(localized: "error.vault.biometryUnavailable.title", defaultValue: "Touch ID is not available")
        case .passwordRequired:
            String(localized: "error.vault.passwordRequired.title", defaultValue: "Master password required")
        case .cancelled:
            String(localized: "error.vault.cancelled.title", defaultValue: "Cancelled")
        case .passwordFallbackRequested:
            String(localized: "error.vault.passwordFallback.title", defaultValue: "Use your master password")
        case .notInitialized:
            String(localized: "error.vault.notInitialized.title", defaultValue: "No vault yet")
        case .alreadyInitialized:
            String(localized: "error.vault.alreadyInitialized.title", defaultValue: "A vault already exists")
        }
    }

    /// What happened and what the user can do.
    var localizedMessage: String {
        switch self {
        case .wrongPassword:
            String(
                localized: "error.vault.wrongPassword.message",
                defaultValue: "Check the master password and try again."
            )
        case .invalidRecoveryKey:
            String(
                localized: "error.vault.invalidRecoveryKey.message",
                defaultValue: "Check that you entered all \(Limits.recoveryKeyCharacters) characters of the current recovery key."
            )
        case .locked:
            String(
                localized: "error.vault.locked.message",
                defaultValue: "The vault locked before the operation finished. Unlock it and try again."
            )
        case .corrupted(let corruption):
            corruption.localizedMessage
        case .biometryInvalidated:
            String(
                localized: "error.vault.biometryInvalidated.message",
                defaultValue: "Touch ID changed on this Mac, so FX Vault turned it off. Unlock with your master password, then turn Touch ID on again in Settings."
            )
        case .biometryUnavailable(let reason):
            reason.localizedMessage
        case .passwordRequired(let reason):
            reason.localizedMessage
        case .cancelled:
            String(localized: "error.vault.cancelled.message", defaultValue: "Nothing was changed.")
        case .passwordFallbackRequested:
            String(
                localized: "error.vault.passwordFallback.message",
                defaultValue: "Enter your master password to continue."
            )
        case .notInitialized:
            String(localized: "error.vault.notInitialized.message", defaultValue: "Create a vault first.")
        case .alreadyInitialized:
            String(
                localized: "error.vault.alreadyInitialized.message",
                defaultValue: "Unlock the existing vault, or reset it in Settings › Advanced."
            )
        }
    }
}

nonisolated extension VaultCorruption {
    var localizedMessage: String {
        switch self {
        case .keyCheckMismatch:
            String(
                localized: "error.vault.corrupted.keyCheckMismatch",
                defaultValue: "The unlocked key does not match this vault. Unlock with your master password."
            )
        case .fieldDecryptionFailed:
            String(
                localized: "error.vault.corrupted.fieldDecryptionFailed",
                defaultValue: "A stored value could not be decrypted. It may have been modified outside FX Vault."
            )
        case .unsupportedFormatVersion:
            String(
                localized: "error.vault.corrupted.unsupportedFormatVersion",
                defaultValue: "This vault was written by a newer version of FX Vault. Update FX Vault to open it."
            )
        case .invalidWrapFormat, .kdfParametersOutOfBounds, .missingVaultRecord, .missingKeyWrap, .invalidStoredValue:
            String(
                localized: "error.vault.corrupted.generic",
                defaultValue: "The vault's key data is damaged. Restore the vault folder from a backup, or reset the vault."
            )
        }
    }
}

nonisolated extension BiometryUnavailableReason {
    var localizedMessage: String {
        switch self {
        case .unsignedBuild:
            String(
                localized: "biometry.unavailable.unsignedBuild",
                defaultValue: "Touch ID requires the official signed release."
            )
        case .notAvailable:
            String(
                localized: "biometry.unavailable.notAvailable",
                defaultValue: "This Mac has no Touch ID sensor available right now."
            )
        case .notEnrolled:
            String(
                localized: "biometry.unavailable.notEnrolled",
                defaultValue: "Add a fingerprint in System Settings › Touch ID & Password first."
            )
        case .lockout:
            String(
                localized: "biometry.unavailable.lockout",
                defaultValue: "Touch ID is locked after too many attempts. Use your master password."
            )
        case .passcodeNotSet:
            String(
                localized: "biometry.unavailable.passcodeNotSet",
                defaultValue: "Touch ID needs a login password on this Mac."
            )
        case .notEnabled:
            String(
                localized: "biometry.unavailable.notEnabled",
                defaultValue: "Touch ID is not turned on for this vault."
            )
        }
    }
}

nonisolated extension PasswordRequiredReason {
    var localizedMessage: String {
        switch self {
        case .restart:
            String(
                localized: "lock.passwordRequired.restart",
                defaultValue: "Your Mac restarted, so FX Vault needs your master password once before Touch ID works again."
            )
        case .periodic:
            String(
                localized: "lock.passwordRequired.periodic",
                defaultValue: "FX Vault asks for your master password at least every \(Timeouts.passwordMaxAge.wholeDays) days."
            )
        case .biometryChanged:
            String(
                localized: "lock.passwordRequired.biometryChanged",
                defaultValue: "Touch ID fingerprints changed. Enter your master password, then turn Touch ID on again in Settings."
            )
        }
    }
}
