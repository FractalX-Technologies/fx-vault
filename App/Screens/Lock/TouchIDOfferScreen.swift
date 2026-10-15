import SwiftUI
import VaultCore

/// The sheet "Unlock FX Vault with Touch ID" over the lock screen, right after a password
/// unlock (v0.1.1). Esc is Not Now; it cannot be swiped away. Laid out as a FractalX sheet
/// (board SyncReview).
struct TouchIDOfferScreen: View {
    @Bindable var viewModel: TouchIDOfferViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(
                label: String(localized: "touchIDOffer.label", defaultValue: "Touch ID"),
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
            .fxTextStyle(.callout)
            .foregroundStyle(Theme.Colors.mutedText)
            .fixedSize(horizontal: false, vertical: true)

            if let error = viewModel.error {
                InlineErrorView(error: error)
            }

            ShellFooter(isWorking: viewModel.isWorking) {
                if viewModel.error == nil {
                    Button(String(localized: "touchIDOffer.notNow", defaultValue: "Not Now")) {
                        viewModel.notNow()
                    }
                    .fxButtonStyle(.secondary, size: .large)
                    .keyboardShortcut(.cancelAction)
                    .disabled(viewModel.isWorking)

                    Button {
                        Task { await viewModel.enable() }
                    } label: {
                        Label(String(localized: "touchIDOffer.enable", defaultValue: "Turn On Touch ID"), systemImage: "touchid")
                    }
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canEnable)
                } else {
                    Button(String(localized: "touchIDOffer.continue", defaultValue: "Continue")) {
                        viewModel.notNow()
                    }
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .fxSheetContent(width: Theme.Layout.sheetWidth)
        .interactiveDismissDisabled()
    }
}
