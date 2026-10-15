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
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Label {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(String(localized: "share.reauth.title", defaultValue: "Confirm it's you"))
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(message)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Theme.Colors.accent)
            }
            HStack(spacing: Theme.Spacing.small) {
                SecureField(
                    String(localized: "share.reauth.password", defaultValue: "Master password"),
                    text: $model.password
                )
                .textFieldStyle(.roundedBorder)
                .focused($isPasswordFocused)
                .onSubmit(submitPassword)
                .disabled(model.isAuthorizing)
                Button(String(localized: "share.reauth.continue", defaultValue: "Continue"), action: submitPassword)
                    .disabled(!model.canSubmitPassword)
            }
            HStack {
                if model.canUseTouchID {
                    Button {
                        Task { await onTouchID() }
                    } label: {
                        Label(
                            String(localized: "share.reauth.touchID", defaultValue: "Use Touch ID"),
                            systemImage: "touchid"
                        )
                    }
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
