import Foundation
import VaultCore
import VaultCrypto
import VaultStore

/// A new master password was rejected by the strength rule (D8).
public enum PasswordPolicyError: Error, Sendable, Hashable {
    /// Shorter than `Limits.minPasswordLength` or below `Limits.minPasswordStrengthBits`. The
    /// model carries the weaknesses the app turns into hints.
    case tooWeak(PasswordStrengthModel)
}

/// The rules around the master password (D8, D14, §5.5). Pure and unit-tested.
enum PasswordRules {
    /// Throws ``PasswordPolicyError/tooWeak(_:)`` unless `password` meets D8 (at least 12
    /// characters and an estimated 60 bits). Checked again here so no caller can skip the UI check.
    static func validateNewPassword(_ password: String) throws(PasswordPolicyError) {
        let strength = PasswordStrength.evaluate(password)
        guard strength.isAcceptable else { throw .tooWeak(strength) }
    }

    /// Why Touch ID must not unlock now, or nil when it may (§5.5). Fails closed: an unknown boot
    /// session counts as a restart, a missing or future timestamp as expired.
    ///
    /// - Parameters:
    ///   - vault: the `vaults` row (last password check, boot session, enrolled state hash).
    ///   - now: wall-clock time.
    ///   - bootSession: the current `kern.bootsessionuuid`.
    ///   - currentStateHash: the current enrollment fingerprint; nil when Touch ID is unavailable
    ///     (the enrollment rule is then skipped and availability decides).
    static func passwordRequirement(
        vault: VaultRecord,
        now: Date,
        bootSession: String?,
        currentStateHash: Data?
    ) -> PasswordRequiredReason? {
        guard
            let bootSession,
            let storedBootSession = vault.lastPasswordBootSession,
            bootSession == storedBootSession
        else { return .restart }

        guard
            let lastCheck = vault.lastPasswordUnlockAt,
            now >= lastCheck,
            now.timeIntervalSince(lastCheck) <= Timeouts.passwordMaxAge.timeInterval
        else { return .periodic }

        if let currentStateHash, let enrolled = vault.biometryStateHash, currentStateHash != enrolled {
            return .biometryChanged
        }
        return nil
    }
}
