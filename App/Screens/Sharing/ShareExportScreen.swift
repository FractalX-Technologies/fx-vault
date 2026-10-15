import SharingKit
import SwiftUI
import VaultData

/// Share › File… (§10 `ShareExportScreen`): ReauthGate → scope tree → passphrase → save or
/// AirDrop. See ``ShareExportViewModel`` for the rules.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.shareExport`.
struct ShareExportScreen: View {
    @State private var viewModel: ShareExportViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: ShareExportContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: ShareExportViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            ShareSheetHeader(
                systemImage: "doc.badge.arrow.up",
                title: String(localized: "shareExport.title", defaultValue: "Share as File"),
                subtitle: String(
                    localized: "shareExport.subtitle",
                    defaultValue: "An encrypted .fxvault file that only opens with its six-word passphrase."
                )
            )
            Divider()
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(Theme.Spacing.xLarge)
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
            HStack(spacing: Theme.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "shareExport.creating", defaultValue: "Encrypting the share…"))
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        case .passphrase:
            passphraseStep
        }
    }

    private var scopeStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(String(localized: "shareExport.scope.title", defaultValue: "What to share"))
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.textPrimary)
            if let tree = viewModel.tree {
                ShareScopeTreeView(tree: tree) { checked, node in
                    viewModel.setChecked(checked, for: node)
                }
            } else if viewModel.isLoadingTree {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: Theme.Layout.shareListHeight)
            }
            if let preview = viewModel.preview {
                ShareExportSummaryView(preview: preview)
            }
        }
    }

    private var passphraseStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(String(localized: "shareExport.passphrase.title", defaultValue: "Passphrase"))
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.textPrimary)
            if let passphrase = viewModel.passphrase {
                PassphraseView(passphrase: passphrase) {
                    viewModel.copyPassphrase()
                }
            }
            ShareNoteView(
                systemImage: "exclamationmark.bubble",
                text: String(
                    localized: "shareExport.passphrase.hint",
                    defaultValue: "Send the passphrase through a different app than the file"
                ),
                tint: Theme.Colors.warning
            )
            Toggle(
                String(localized: "shareExport.passphrase.saved", defaultValue: "I've saved it"),
                isOn: Binding(
                    get: { viewModel.hasSavedPassphrase },
                    set: { viewModel.hasSavedPassphrase = $0 }
                )
            )
            .toggleStyle(.checkbox)
            HStack(spacing: Theme.Spacing.small) {
                Button {
                    Task { await viewModel.saveToFile() }
                } label: {
                    Label(String(localized: "shareExport.save", defaultValue: "Save…"), systemImage: "square.and.arrow.down")
                }
                Button {
                    viewModel.shareFile()
                } label: {
                    Label(String(localized: "shareExport.airDrop", defaultValue: "AirDrop…"), systemImage: "square.and.arrow.up")
                }
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
        HStack {
            Spacer()
            if viewModel.step == .passphrase {
                Button(String(localized: "common.done", defaultValue: "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if viewModel.step == .chooseScope || viewModel.step == .creating {
                    Button(String(localized: "shareExport.create", defaultValue: "Create Share File")) {
                        Task { await viewModel.createShareFile() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canCreate)
                }
            }
        }
    }
}

/// What the checked scope contains: names and counts only.
private struct ShareExportSummaryView: View {
    let preview: ShareExportPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            ShareNoteView(
                systemImage: "shippingbox",
                text: String(
                    localized: "shareExport.summary",
                    defaultValue: "\(preview.itemCount) items and \(preview.environmentNames.count) environments from \(preview.repositoryFullName)"
                )
            )
            if !preview.valueMissingNames.isEmpty {
                ShareNoteView(
                    systemImage: "exclamationmark.triangle",
                    text: String(
                        localized: "shareExport.summary.valueMissing",
                        defaultValue: "\(preview.valueMissingNames.count) secrets have no value in your vault and are shared by name only."
                    ),
                    tint: Theme.Colors.warning
                )
            }
        }
    }
}
