import SharingKit
import SwiftUI
import VaultData

/// Share › Receive Nearby… (§10 `NearbyShareScreen`, receive; experimental): "Waiting for a
/// teammate…" → code → manifest preview → Accept/Reject → Same/Differs confirmation → result.
/// FX Vault advertises only while this sheet is open. See ``NearbyReceiveViewModel``.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.nearbyReceive`.
struct NearbyReceiveScreen: View {
    @State private var viewModel: NearbyReceiveViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: NearbyReceiveContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: NearbyReceiveViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(
                label: ShareSheetLabel.nearby,
                title: String(localized: "nearbyReceive.title", defaultValue: "Receive Nearby"),
                subtitle: String(
                    localized: "nearbyReceive.subtitle",
                    defaultValue: "Receive configuration from a teammate's Mac nearby. This Mac is visible only while this window is open."
                ),
                isExperimental: true
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
        case .waiting:
            NearbyProgressRow(text: String(localized: "nearbyReceive.waiting", defaultValue: "Waiting for a teammate…"))
        case .comparing(let sas):
            SASCodeView(sas: sas, isConfirmed: false, isPeerConfirmed: viewModel.isPeerConfirmed) { decision in
                Task { await viewModel.decide(decision) }
            }
        case .awaitingManifest(let sas):
            SASCodeView(sas: sas, isConfirmed: true, isPeerConfirmed: viewModel.isPeerConfirmed) { _ in }
        case .reviewingManifest:
            reviewStep(
                note: String(
                    localized: "nearbyReceive.manifest.note",
                    defaultValue: "Review what your teammate offers. Values are sent only after you accept, and you confirm them again before anything is imported."
                )
            )
        case .receiving:
            NearbyProgressRow(text: String(localized: "nearbyReceive.receiving", defaultValue: "Receiving…"))
        case .confirmingPayload, .applying:
            reviewStep(
                note: String(
                    localized: "nearbyReceive.payload.note",
                    defaultValue: "The values arrived. Check Same and Differs, then import. Items that differ keep your value unless you choose Overwrite."
                )
            )
        case .done:
            if let result = viewModel.result {
                ShareImportResultView(result: result)
            }
        case .declined:
            SheetCallout(
                systemImage: "xmark.circle",
                tint: Theme.Colors.subtleText,
                text: String(localized: "nearbyReceive.declined", defaultValue: "Declined. Nothing was imported.")
            )
        case .failed:
            NearbyFailureView(abort: viewModel.abort, showsInterceptionWarning: viewModel.showsInterceptionWarning)
        }
    }

    private func reviewStep(note: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ShareNoteView(systemImage: "info.circle", text: note)
            if let editor = viewModel.editor {
                if let reason = editor.blockReason {
                    Banner(.danger, message: reason.localizedMessage)
                    if viewModel.needsRepositoryImport {
                        ShareImportRepositoryButton(
                            title: String(
                                localized: "nearbyReceive.importRepo",
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
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            if viewModel.canTryAgain {
                Button(String(localized: "nearby.receiveAgain", defaultValue: "Receive Again")) {
                    Task { await viewModel.start() }
                }
                .fxButtonStyle(.outline, size: .large)
            }
            Spacer()
            switch viewModel.step {
            case .reviewingManifest:
                Button(String(localized: "nearbyReceive.reject", defaultValue: "Reject")) {
                    Task { await viewModel.reject() }
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "nearbyReceive.accept", defaultValue: "Accept")) {
                    Task { await viewModel.accept() }
                }
                .fxButtonStyle(.primary, size: .large)
                .disabled(!viewModel.canAccept)
            case .confirmingPayload, .applying:
                Button(String(localized: "nearbyReceive.rejectValues", defaultValue: "Reject")) {
                    Task { await viewModel.rejectPayload() }
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.step == .applying)
                Button(String(localized: "nearbyReceive.apply", defaultValue: "Import")) {
                    Task { await viewModel.apply() }
                }
                .fxButtonStyle(.primary, size: .large)
                .disabled(!viewModel.canApply)
            case .done, .declined, .failed:
                Button(String(localized: "common.done", defaultValue: "Done")) {
                    dismiss()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
            default:
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
            }
        }
    }
}
