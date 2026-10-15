import SwiftUI
import VaultCore
import VaultCrypto

/// A segmented strength bar, a mono status line ("STRONG · 96 BITS") and, until the password is
/// acceptable, the most useful hint (D8: at least 12 characters and 60 bits; board Onboarding).
struct PasswordStrengthMeter: View {
    let strength: PasswordStrengthModel

    /// The bar is drawn as this many equal segments.
    private static let segmentCount = 4

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.smallMinus) {
                ForEach(0..<Self.segmentCount, id: \.self) { index in
                    Capsule.pill
                        .fill(index < filledSegments ? tint : Theme.Colors.surface2)
                        .frame(height: Theme.Layout.strengthBarHeight)
                }
            }
            .animation(Theme.Durations.interactionAnimation, value: filledSegments)
            .accessibilityHidden(true)

            if let status {
                Text(status)
                    .fxTextStyle(.statusLine)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            if let hint {
                Text(hint)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var filledSegments: Int {
        guard strength.level != .empty else { return 0 }
        let fraction = min(1, max(0, strength.meterFraction))
        return max(1, Int((fraction * Double(Self.segmentCount)).rounded(.up)))
    }

    private var tint: Color {
        switch strength.level {
        case .empty, .weak: Theme.Colors.warning
        case .acceptable: Theme.Colors.brand
        case .strong: Theme.Colors.success
        }
    }

    /// "Weak · 41 bits"; nil while the field is empty.
    private var status: String? {
        let bits = Int(strength.estimatedBits.rounded(.down))
        let level: String
        switch strength.level {
        case .empty:
            return nil
        case .weak:
            level = String(localized: "password.strength.level.weak", defaultValue: "Weak")
        case .acceptable:
            level = String(localized: "password.strength.level.good", defaultValue: "Good")
        case .strong:
            level = String(localized: "password.strength.level.strong", defaultValue: "Strong")
        }
        return String(localized: "password.strength.status", defaultValue: "\(level) · \(bits) bits")
    }

    /// The requirement while empty, the most useful fix while weak; nil once acceptable.
    private var hint: String? {
        switch strength.level {
        case .empty:
            String(
                localized: "password.strength.empty",
                defaultValue: "At least \(Limits.minPasswordLength) characters. A passphrase of several words works well."
            )
        case .weak:
            strength.primaryHint
                ?? String(localized: "password.weakness.generic", defaultValue: "Choose a stronger master password.")
        case .acceptable, .strong:
            nil
        }
    }

    private var accessibilityText: String {
        switch strength.level {
        case .empty, .weak:
            [status, hint].compactMap { $0 }.joined(separator: ". ")
        case .acceptable:
            String(localized: "password.strength.acceptable", defaultValue: "Good password.")
        case .strong:
            String(localized: "password.strength.strong", defaultValue: "Strong password.")
        }
    }
}
