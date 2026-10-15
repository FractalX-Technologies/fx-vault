import SwiftUI
import VaultCore

/// The sheet "Unlock FX Vault with Touch ID" over the lock screen, right after a password
/// unlock (v0.1.1). Esc is Not Now; it cannot be swiped away.
struct TouchIDOfferScreen: View {
    @Bindable var viewModel: TouchIDOfferViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            CardHeader(
                systemImage: "touchid",
                title: String(localized: "touchIDOffer.title", defaultValue: "Unlock FX Vault with Touch ID"),
                subtitle: viewModel.isAfterInvalidation
                    ? String(
                        localized: "touchIDOffer.subtitle.reenable",
                        defaultValue: "The fingerprints on this Mac changed, so Touch ID was turned off. Turn it on again to unlock with your finger."
                    )
                    : String(
                        localized: "touchIDOffer.subtitle",
                        defaultValue: "Use your fingerprint instead of typing the master password."
                    )
            )
            Text(String(
                localized: "touchIDOffer.policy",
                defaultValue: "FX Vault still asks for the master password after a restart and at least every \(Timeouts.passwordMaxAge.wholeDays) days. You can change this later in Settings › Security."
            ))
            .font(Theme.Typography.callout)
            .foregroundStyle(Theme.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if let error = viewModel.error {
                InlineErrorView(error: error)
            }

            HStack {
                Spacer()
                if viewModel.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                if viewModel.error == nil {
                    Button(String(localized: "touchIDOffer.notNow", defaultValue: "Not Now")) {
                        viewModel.notNow()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(viewModel.isWorking)

                    Button(String(localized: "touchIDOffer.enable", defaultValue: "Turn On Touch ID")) {
                        Task { await viewModel.enable() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canEnable)
                } else {
                    Button(String(localized: "touchIDOffer.continue", defaultValue: "Continue")) {
                        viewModel.notNow()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: Theme.Layout.sheetWidth)
        .interactiveDismissDisabled()
    }
}
