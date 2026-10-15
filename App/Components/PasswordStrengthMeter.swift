import SwiftUI
import VaultCore
import VaultCrypto

/// A thin strength bar plus the most useful hint (D8: at least 12 characters and 60 bits).
struct PasswordStrengthMeter: View {
    let strength: PasswordStrengthModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Colors.textSecondary.opacity(Theme.Opacity.chipBackground))
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * strength.meterFraction)
                }
            }
            .frame(height: Theme.Layout.strengthBarHeight)
            .animation(Theme.Durations.standardAnimation, value: strength.meterFraction)
            .accessibilityHidden(true)

            Text(caption)
                .font(Theme.Typography.caption)
                .foregroundStyle(strength.level == .weak ? Theme.Colors.warning : Theme.Colors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch strength.level {
        case .empty, .weak: Theme.Colors.warning
        case .acceptable: Theme.Colors.accent
        case .strong: Theme.Colors.success
        }
    }

    private var caption: String {
        switch strength.level {
        case .empty:
            String(
                localized: "password.strength.empty",
                defaultValue: "At least \(Limits.minPasswordLength) characters. A passphrase of several words works well."
            )
        case .weak:
            strength.primaryHint
                ?? String(localized: "password.weakness.generic", defaultValue: "Choose a stronger master password.")
        case .acceptable:
            String(localized: "password.strength.acceptable", defaultValue: "Good password.")
        case .strong:
            String(localized: "password.strength.strong", defaultValue: "Strong password.")
        }
    }
}
