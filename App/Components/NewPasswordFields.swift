import SwiftUI
import VaultCrypto

/// New master password, confirmation and strength meter (onboarding, recovery reset, change
/// password): labelled FractalX inputs (board Onboarding).
struct NewPasswordFields: View {
    @Binding var password: String
    @Binding var confirmation: String
    let strength: PasswordStrengthModel
    let showsMismatch: Bool
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
                FXTextField(
                    label: String(localized: "password.new.placeholder", defaultValue: "Master password"),
                    text: $password,
                    isSecure: true
                )
                .textContentType(.newPassword)
                .accessibilityIdentifier(AccessibilityID.NewPassword.password)
                PasswordStrengthMeter(strength: strength)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                FXTextField(
                    label: String(localized: "password.confirm.placeholder", defaultValue: "Confirm master password"),
                    text: $confirmation,
                    isSecure: true,
                    isInvalid: showsMismatch
                )
                .textContentType(.newPassword)
                .accessibilityIdentifier(AccessibilityID.NewPassword.confirmation)
                .onSubmit(onSubmit)
                if showsMismatch {
                    Text(String(localized: "password.mismatch", defaultValue: "The passwords do not match."))
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.danger)
                }
            }
        }
    }
}
