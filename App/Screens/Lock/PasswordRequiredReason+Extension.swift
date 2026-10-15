import VaultCore

nonisolated extension PasswordRequiredReason {
    /// The short reason under the lock screen's password field while Touch ID is on but the
    /// master password is required ("After a restart", "Every 14 days"). The full explanation is
    /// ``localizedMessage``.
    var localizedShortTitle: String {
        switch self {
        case .restart:
            String(localized: "lock.passwordRequired.short.restart", defaultValue: "After a restart")
        case .periodic:
            String(
                localized: "lock.passwordRequired.short.periodic",
                defaultValue: "Every \(Timeouts.passwordMaxAge.wholeDays) days"
            )
        case .biometryChanged:
            String(localized: "lock.passwordRequired.short.biometryChanged", defaultValue: "Fingerprints changed")
        }
    }
}

/// A Touch ID note under the lock screen's password field: an optional bold title and the
/// explanation.
struct LockNoticeModel: Equatable {
    let title: String?
    let detail: String
}
