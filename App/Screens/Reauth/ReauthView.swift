import SwiftUI

/// "Confirm it's you" before a share or Copy All (D30): Touch ID, or the master password, in the
/// dialog form of the 1.0 sheets (board Share-Pick's language).
struct ReauthView<Authorization: ReauthAuthorization>: View {
    let model: ReauthModel<Authorization>
    let message: String
    let onTouchID: () async -> Void
    let onPassword: () async -> Void

    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        @Bindable var model = model
        let passwordLabel = String(localized: "share.reauth.password", defaultValue: "Master password")
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text(String(localized: "share.reauth.title", defaultValue: "Confirm it's you"))
                .fxTextStyle(.headline)
                .foregroundStyle(Theme.Colors.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        DialogFormRow(passwordLabel) {
            HStack(spacing: Theme.Spacing.small) {
                SecureField(passwordLabel, text: $model.password)
                    .focused($isPasswordFocused)
                    .fxInputField(.dialog, isFocused: isPasswordFocused)
                    .onSubmit(submitPassword)
                    .disabled(model.isAuthorizing)
                    .accessibilityIdentifier(AccessibilityID.Share.password)
                Button(String(localized: "share.reauth.continue", defaultValue: "Continue"), action: submitPassword)
                    .fxButtonStyle(.primary, size: .dialog)
                    .disabled(!model.canSubmitPassword)
                    .accessibilityIdentifier(AccessibilityID.Share.passwordContinue)
            }
        }
        .onChange(of: model.focusPasswordRequest) {
            isPasswordFocused = true
        }
        HStack(spacing: Theme.Spacing.medium) {
            if model.canUseTouchID {
                Button {
                    Task { await onTouchID() }
                } label: {
                    Label(
                        String(localized: "share.reauth.touchID", defaultValue: "Use Touch ID"),
                        systemImage: "touchid"
                    )
                }
                .fxButtonStyle(.outline, size: .dialog)
                .disabled(model.isAuthorizing)
            }
            if model.isAuthorizing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        if let error = model.error {
            InlineErrorView(error: error)
        }
    }

    private func submitPassword() {
        Task { await onPassword() }
    }
}
