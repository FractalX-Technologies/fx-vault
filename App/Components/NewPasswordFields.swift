import SwiftUI
import VaultCrypto

/// New master password, confirmation and strength meter (onboarding, recovery reset, change
/// password).
struct NewPasswordFields: View {
    @Binding var password: String
    @Binding var confirmation: String
    let strength: PasswordStrengthModel
    let showsMismatch: Bool
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SecureField(
                String(localized: "password.new.placeholder", defaultValue: "Master password"),
                text: $password
            )
            .textContentType(.newPassword)
            PasswordStrengthMeter(strength: strength)
            SecureField(
                String(localized: "password.confirm.placeholder", defaultValue: "Confirm master password"),
                text: $confirmation
            )
            .textContentType(.newPassword)
            .onSubmit(onSubmit)
            if showsMismatch {
                Text(String(localized: "password.mismatch", defaultValue: "The passwords do not match."))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.danger)
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}
