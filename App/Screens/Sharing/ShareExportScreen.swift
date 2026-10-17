import SharingKit
import SwiftUI
import VaultData

/// Nearby Chat › Save as File… (§10 `ShareExportScreen`): ReauthGate → what was received →
/// passphrase → save or AirDrop. See ``ShareExportViewModel`` for the rules.
///
/// Presented by `NearbyChatScreen`; sharing from the vault is ``ProjectShareScreen`` (v0.9.0).
struct ShareExportScreen: View {
    @State private var viewModel: ShareExportViewModel
    @Environment(\.dismiss) private var dismiss

    /// Shows the chat's view model (and the visual snapshot tests').
    init(viewModel: ShareExportViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(
                label: ShareSheetLabel.nearbyChat,
                title: String(localized: "shareExport.chat.title", defaultValue: "Save as File"),
                subtitle: String(
                    localized: "shareExport.subtitle",
                    defaultValue: "An encrypted .fxvault file that only opens with its six-word passphrase."
                )
            )
            content
            Spacer(minLength: 0)
            footer
        }
        .fxSheetContent()
        .frame(width: Theme.Layout.shareSheetWidth)
        .frame(minHeight: Theme.Layout.shareSheetMinHeight)
        .task { await viewModel.start() }
        .onDisappear { viewModel.close() }
        .errorAlert($viewModel.alert)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .authenticate:
            ShareReauthView(
                model: viewModel.reauth,
                message: String(
                    localized: "shareExport.reauth.message",
                    defaultValue: "Sharing exports values. Use Touch ID or your master password to continue."
                ),
                onTouchID: { await viewModel.authenticateWithTouchID() },
                onPassword: { await viewModel.authenticateWithPassword() }
            )
        case .chooseScope:
            scopeStep
        case .creating:
            NearbyProgressRow(text: String(localized: "shareExport.creating", defaultValue: "Encrypting the share…"))
        case .passphrase:
            passphraseStep
        }
    }

    private var scopeStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SectionLabel(String(localized: "shareExport.chat.scope.title", defaultValue: "Received in Nearby Chat"))
            if let preview = viewModel.preview {
                ShareContentSummaryView(preview: preview)
            }
        }
    }

    private var passphraseStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            if let passphrase = viewModel.passphrase {
                PassphraseView(passphrase: passphrase) {
                    viewModel.copyPassphrase()
                }
            }
            SheetCallout(
                systemImage: "exclamationmark.bubble",
                tint: Theme.Colors.warning,
                text: String(
                    localized: "shareExport.passphrase.hint",
                    defaultValue: "Send the passphrase through a different app than the file"
                )
            )
            Toggle(
                String(localized: "shareExport.passphrase.saved", defaultValue: "I've saved it"),
                isOn: Binding(
                    get: { viewModel.hasSavedPassphrase },
                    set: { viewModel.hasSavedPassphrase = $0 }
                )
            )
            .toggleStyle(.checkbox)
            .fxTextStyle(.callout)
            .foregroundStyle(Theme.Colors.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fxCalloutBackground()
            HStack(spacing: Theme.Spacing.small) {
                Button {
                    Task { await viewModel.saveToFile() }
                } label: {
                    Label(String(localized: "shareExport.save", defaultValue: "Save…"), systemImage: "square.and.arrow.down")
                }
                .fxButtonStyle(.primary)
                Button {
                    viewModel.shareFile()
                } label: {
                    Label(String(localized: "shareExport.airDrop", defaultValue: "AirDrop…"), systemImage: "square.and.arrow.up")
                }
                .fxButtonStyle(.secondary)
                .background(ShareDeliveryAnchor(delivery: viewModel.delivery))
                if viewModel.isDelivering {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .disabled(!viewModel.canDeliver)
            if let notice = viewModel.notice {
                ShareNoteView(systemImage: "checkmark.circle", text: notice, tint: Theme.Colors.success)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Spacer()
            if viewModel.step == .passphrase {
                Button(String(localized: "common.done", defaultValue: "Done")) {
                    dismiss()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
            } else {
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
                if viewModel.step == .chooseScope || viewModel.step == .creating {
                    Button(String(localized: "shareExport.create", defaultValue: "Create Share File")) {
                        Task { await viewModel.createShareFile() }
                    }
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canCreate)
                }
            }
        }
    }
}
