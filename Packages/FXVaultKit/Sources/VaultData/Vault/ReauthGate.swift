import os
import VaultCore

/// Operations that need a fresh proof of presence: Touch ID **or** the master password (D30).
public enum ReauthPurpose: String, Sendable, Hashable, CaseIterable {
    /// Writing a plaintext `.env` file.
    case export
    /// Writing a `.fxvault` file.
    case share
    /// Copy All (1.0 D6c4): every value of a place, as `.env` text, on the clipboard.
    case copyAll
    /// Reveal in a place's notes (1.0 B9): one secret shown until it re-masks.
    case reveal
    /// Reveal All in a place's notes: every secret of the place shown until they re-mask.
    case revealAll
    /// Copy of one secret from the quick vault (1.0 Q1), where Copy sits beside the mask.
    case copyValue
    /// Save As… of a folder file (v23): its bytes written to disk unsealed.
    case saveFile
}

/// Operations that accept **only** the master password (D30). Touch ID never authorizes them:
/// someone at an unlocked Mac must not be able to take a recovery key or change credentials.
public enum PasswordReauthPurpose: String, Sendable, Hashable, CaseIterable {
    case newRecoveryKey
    case changePassword
    case disableTouchID
    case rotateKey
    case resetVault
}

/// How the user proves presence for a ``ReauthPurpose``.
public enum ReauthCredential: Sendable {
    /// Read the Touch ID item (one prompt) and verify it against the vault's key-check value.
    case biometrics(BiometricPrompt)
    /// Verify the master password by unwrapping the DEK.
    case password(String)
}

/// Re-authentication before sensitive operations (§5.6, D30).
///
/// Both methods require an unlocked vault and prove that the credential opens **this** vault's
/// current DEK. Neither uses `.deviceOwnerAuthentication`, which would accept the macOS login
/// password. A Touch ID check obeys the same rules as a Touch ID unlock (restart, 14 days,
/// enrollment change). A password check counts as a password unlock for those rules.
///
/// The password-only operations of ``VaultManager`` (``VaultManager/changePassword(current:new:rotate:)``,
/// ``VaultManager/newRecoveryKey(password:)``, ``VaultManager/disableBiometrics(password:)``,
/// ``VaultManager/rotateDEK(password:)``, ``VaultManager/resetVault(password:)``) verify the
/// password themselves; ``authorizeWithPassword(_:password:)`` is for flows that need the same
/// guarantee before showing UI.
public struct ReauthGate: Sendable {
    private let manager: VaultManager

    public init(manager: VaultManager) {
        self.manager = manager
    }

    /// Authorizes an export or share with either credential.
    ///
    /// - Throws: `VaultError.locked`; for `.password`: `.wrongPassword`; for `.biometrics`:
    ///   `.cancelled`, `.passwordFallbackRequested`, `.passwordRequired(reason:)`, `.biometryUnavailable(_:)`,
    ///   `.biometryInvalidated`, `.corrupted(.keyCheckMismatch)`. After any Touch ID failure the
    ///   app offers the password field.
    public func authorize(_ purpose: ReauthPurpose, with credential: ReauthCredential) async throws {
        switch credential {
        case .biometrics(let prompt):
            try await manager.reauthenticate(prompt: prompt)
        case .password(let password):
            try await manager.reauthenticate(password: password)
        }
        VaultManagerConstants.log.info("Re-authenticated for \(purpose.rawValue, privacy: .public)")
    }

    /// Authorizes a password-only operation (no Touch ID path exists).
    ///
    /// - Throws: `VaultError.locked`, `.wrongPassword`.
    public func authorizeWithPassword(_ purpose: PasswordReauthPurpose, password: String) async throws {
        try await manager.reauthenticate(password: password)
        VaultManagerConstants.log.info("Re-authenticated with the password for \(purpose.rawValue, privacy: .public)")
    }
}
