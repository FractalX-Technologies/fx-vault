import VaultCore
import VaultCrypto
import VaultData

/// How strong a candidate master password looks, for the strength meter.
nonisolated enum PasswordStrengthLevel: Equatable {
    case empty
    case weak
    case acceptable
    case strong

    /// Margin over the D8 minimum at which a password counts as strong.
    private static let strongMarginFactor = 1.5
    /// Estimated bits at which a password counts as strong.
    static let strongBits = Double(Limits.minPasswordStrengthBits) * strongMarginFactor
}

nonisolated extension PasswordStrengthModel {
    var level: PasswordStrengthLevel {
        if characterCount == 0 { return .empty }
        guard isAcceptable else { return .weak }
        return estimatedBits >= PasswordStrengthLevel.strongBits ? .strong : .acceptable
    }

    /// Fraction of the meter to fill (0...1).
    var meterFraction: Double {
        min(1, estimatedBits / PasswordStrengthLevel.strongBits)
    }

    /// The most useful hint for a password that is not acceptable yet, or nil.
    var primaryHint: String? {
        guard !isAcceptable, characterCount > 0 else { return nil }
        let weakness = weaknesses.first { $0 != .lowEstimatedStrength } ?? weaknesses.first
        return weakness?.localizedHint
    }
}

nonisolated extension PasswordWeakness {
    var localizedHint: String {
        switch self {
        case .tooShort:
            String(
                localized: "password.weakness.tooShort",
                defaultValue: "Use at least \(Limits.minPasswordLength) characters."
            )
        case .lowEstimatedStrength:
            String(
                localized: "password.weakness.lowEstimatedStrength",
                defaultValue: "Too easy to guess. Add more words or characters, or generate a passphrase."
            )
        case .commonWord:
            String(localized: "password.weakness.commonWord", defaultValue: "Avoid common passwords and words.")
        case .sequence:
            String(localized: "password.weakness.sequence", defaultValue: "Avoid sequences such as 1234 or abcd.")
        case .keyboardPattern:
            String(localized: "password.weakness.keyboardPattern", defaultValue: "Avoid keyboard patterns such as qwerty.")
        case .repetition:
            String(localized: "password.weakness.repetition", defaultValue: "Avoid repeated characters.")
        case .year:
            String(localized: "password.weakness.year", defaultValue: "Avoid years and dates.")
        }
    }
}

nonisolated extension PasswordPolicyError {
    var localizedMessage: String {
        switch self {
        case .tooWeak(let strength):
            strength.primaryHint
                ?? String(localized: "password.weakness.generic", defaultValue: "Choose a stronger master password.")
        }
    }
}
