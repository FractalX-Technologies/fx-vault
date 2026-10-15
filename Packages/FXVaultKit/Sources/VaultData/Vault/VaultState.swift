import VaultCore

/// The lifecycle state of the vault (§5, §10). `AppViewModel` maps it to its screen phase.
public enum VaultState: Sendable, Hashable, CaseIterable {
    /// No vault exists yet: onboarding.
    case noVault
    /// A vault exists and its keys are not in memory.
    case locked
    /// The keys are installed in ``VaultSession``.
    case unlocked
}

/// Whether the lock screen can offer Touch ID right now (§5.5). Computed without any prompt.
public enum BiometricUnlockStatus: Sendable, Hashable {
    /// Touch ID can unlock: offer (or auto-start) the prompt.
    case available
    /// Touch ID cannot be used (ad-hoc build, not enabled, no sensor, lockout, ...).
    case unavailable(BiometryUnavailableReason)
    /// The master password is required first (restart, 14 days, enrollment change).
    case passwordRequired(PasswordRequiredReason)
}
