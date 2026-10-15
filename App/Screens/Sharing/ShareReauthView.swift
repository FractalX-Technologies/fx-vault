import SwiftUI

/// "Confirm it's you" before a share (D30): Touch ID, or the master password.
struct ShareReauthView: View {
    let model: ShareReauthModel
    let message: String
    let onTouchID: () async -> Void
    let onPassword: () async -> Void

    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        @Bindable var model = model
        let passwordLabel = String(localized: "share.reauth.password", defaultValue: "Master password")
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
                Text(String(localized: "share.reauth.title", defaultValue: "Confirm it's you"))
                    .fxTextStyle(.title2)
                    .foregroundStyle(Theme.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .fxTextStyle(.body)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
                SectionLabel(passwordLabel)
                    .accessibilityHidden(true)
                HStack(spacing: Theme.Spacing.small) {
                    SecureField(passwordLabel, text: $model.password)
                        .focused($isPasswordFocused)
                        .fxInputField(.pill, isFocused: isPasswordFocused)
                        .onSubmit(submitPassword)
                        .disabled(model.isAuthorizing)
                    Button(String(localized: "share.reauth.continue", defaultValue: "Continue"), action: submitPassword)
                        .fxButtonStyle(.primary, size: .large)
                        .disabled(!model.canSubmitPassword)
                }
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
                    .fxButtonStyle(.secondary, size: .large)
                    .disabled(model.isAuthorizing)
                }
                Spacer()
                if model.isAuthorizing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let error = model.error {
                InlineErrorView(error: error)
            }
        }
        .onChange(of: model.focusPasswordRequest) {
            isPasswordFocused = true
        }
    }

    private func submitPassword() {
        Task { await onPassword() }
    }
}
