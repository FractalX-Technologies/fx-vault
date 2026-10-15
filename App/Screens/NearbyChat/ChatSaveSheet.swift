import SharingKit
import SwiftUI
import VaultData

/// "Save to my vault": the share import preview of a secret or variable received in chat
/// (chips, Keep mine for differences, replay and repository checks), then Import. See
/// ``ChatSaveViewModel``.
struct ChatSaveSheet: View {
    let viewModel: ChatSaveViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(
                label: ShareSheetLabel.nearbyChat,
                title: String(localized: "chat.save.title", defaultValue: "Save to My Vault"),
                subtitle: String(
                    localized: "chat.save.subtitle",
                    defaultValue: "\(viewModel.itemName), received in Nearby Chat. Review it before it is imported."
                )
            )
            content
            Spacer(minLength: 0)
            footer
        }
        .fxSheetContent()
        .frame(width: Theme.Layout.shareSheetWidth)
        .frame(minHeight: Theme.Layout.shareSheetMinHeight)
        .task { await viewModel.prepare() }
        .onDisappear { viewModel.finish() }
        .errorAlert($viewModel.alert)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .preparing:
            NearbyProgressRow(text: String(localized: "chat.save.preparing", defaultValue: "Preparing the preview…"))
        case .preview, .applying:
            if let editor = viewModel.editor {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    if let reason = editor.blockReason {
                        Banner(.danger, message: reason.localizedMessage)
                        if viewModel.needsRepositoryImport {
                            ShareImportRepositoryButton(
                                title: String(
                                    localized: "chat.save.importRepo",
                                    defaultValue: "Import \(viewModel.repositoryFullName ?? "") from GitHub"
                                ),
                                isImporting: viewModel.isImportingRepository,
                                isOnline: viewModel.isOnline
                            ) {
                                Task { await viewModel.importRepository() }
                            }
                        }
                    }
                    ShareImportPreviewView(editor: editor)
                }
            }
        case .done:
            if let result = viewModel.result {
                ShareImportResultView(result: result)
            }
        case .failed:
            if let failure = viewModel.failure {
                InlineErrorView(error: failure)
            } else {
                SheetCallout(
                    systemImage: "xmark.circle",
                    tint: Theme.Colors.subtleText,
                    text: String(localized: "chat.save.wiped", defaultValue: "Nothing was imported. The value was wiped.")
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Spacer()
            switch viewModel.step {
            case .done, .failed:
                Button(String(localized: "common.done", defaultValue: "Done")) {
                    viewModel.finish()
                }
                .fxButtonStyle(.primary, size: .large)
                .keyboardShortcut(.defaultAction)
            case .preparing, .preview, .applying:
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    viewModel.finish()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.step == .applying)
                Button(String(localized: "shareImport.apply", defaultValue: "Import")) {
                    Task { await viewModel.apply() }
                }
                .fxButtonStyle(.primary, size: .large)
                .disabled(!viewModel.canApply)
            }
        }
    }
}
