import Foundation

/// How long a project share file can be opened (v0.9.0, P6). FX Vault refuses a file after its
/// `expiresAt`; the date is inside the ciphertext, so the app enforces it, not the cryptography.
public enum ShareExpiryChoice: String, Sendable, Hashable, CaseIterable, Codable {
    case oneDay
    case sevenDays
    case thirtyDays

    /// What a new export offers first.
    public static let `default`: ShareExpiryChoice = .sevenDays

    /// The time from `createdAt` to `expiresAt`.
    public var duration: Duration {
        .seconds(days * Timeouts.secondsPerDay)
    }

    /// The number of days, for the picker's labels.
    public var days: Int64 {
        switch self {
        case .oneDay: 1
        case .sevenDays: 7
        case .thirtyDays: 30
        }
    }

    /// `createdAt` plus ``duration``.
    public func expiry(from createdAt: Date) -> Date {
        createdAt.addingTimeInterval(TimeInterval(days * Timeouts.secondsPerDay))
    }
}
