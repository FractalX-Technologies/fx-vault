/// Vault lifecycle and key errors (§4.4, §5). Carries no localized text; the app maps each case
/// in `VaultError+Extension.swift`.
public enum VaultError: Error, Sendable, Hashable {
    /// The master password did not unwrap the DEK (GCM failure on the password wrap, §5.2).
    case wrongPassword
    /// The recovery key is malformed, fails its checksum, or did not unwrap the DEK (§5.3).
    case invalidRecoveryKey
    /// The vault is locked, or was locked while the operation ran (keyring generation changed).
    case locked
    /// Stored vault data failed an integrity check.
    case corrupted(VaultCorruption)
    /// The Touch ID item was invalidated (enrollment change, -25300/-25293); it was deleted.
    case biometryInvalidated
    /// Touch ID cannot be used.
    case biometryUnavailable(BiometryUnavailableReason)
    /// Touch ID unlock is refused; the master password is required (§5.5).
    case passwordRequired(reason: PasswordRequiredReason)
    /// The user cancelled an authentication prompt.
    case cancelled
    /// The user chose the password fallback ("Use Master Password") in a Touch ID prompt
    /// (`LAError.userFallback`, §5.5). Nothing failed: show and focus the password field.
    case passwordFallbackRequested
    /// No vault exists yet (onboarding has not run).
    case notInitialized
    /// A vault already exists, so it cannot be created again.
    case alreadyInitialized
}

/// What failed an integrity check (`VaultError.corrupted`).
public enum VaultCorruption: String, Sendable, Hashable, CaseIterable {
    /// The unwrapped DEK did not match `vaults.kcv`.
    case keyCheckMismatch
    /// `wrapped_dek` has the wrong length, format byte or AEAD byte.
    case invalidWrapFormat
    /// Stored KDF parameters are outside the accepted bounds (checked before the KDF, §5.2).
    case kdfParametersOutOfBounds
    /// The single `vaults` row is missing or malformed.
    case missingVaultRecord
    /// A `key_wraps` row needed for this unlock method is missing.
    case missingKeyWrap
    /// `format_version` or a blob format byte is newer than this build understands.
    case unsupportedFormatVersion
    /// A field ciphertext failed authentication (tampered row, kind or scope flip, §5.4).
    case fieldDecryptionFailed
    /// A stored value is not valid for its column (for example a non-UTF-8 name).
    case invalidStoredValue
}

/// Why Touch ID cannot be used (`VaultError.biometryUnavailable`).
public enum BiometryUnavailableReason: String, Sendable, Hashable, CaseIterable {
    /// Ad-hoc build without the keychain access group entitlement (D14).
    case unsignedBuild
    /// The Mac has no Touch ID sensor, or it is not available now (clamshell, no keyboard).
    case notAvailable
    /// No fingerprints are enrolled.
    case notEnrolled
    /// Too many failed attempts; the system requires the login password first.
    case lockout
    /// The Mac has no login password, which data-protection keychain items require.
    case passcodeNotSet
    /// Touch ID is not enabled for this vault.
    case notEnabled
}

/// Why the master password is required instead of Touch ID (§5.5).
public enum PasswordRequiredReason: String, Sendable, Hashable, CaseIterable {
    /// The Mac restarted since the last password unlock (`kern.bootsessionuuid` changed).
    case restart
    /// The last password unlock is older than ``Timeouts/passwordMaxAge``.
    case periodic
    /// Touch ID enrollment changed (biometry state hash differs).
    case biometryChanged
}
