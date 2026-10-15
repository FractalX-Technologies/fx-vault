import SharingKit
import SwiftUI
import VaultCore
import VaultData

/// Share › Nearby… (§10 `NearbyShareScreen`, send; experimental): peers → handshake → code →
/// ReauthGate → waiting for the decision → progress → result. See ``NearbySendViewModel``.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.nearbySend`.
struct NearbySendScreen: View {
    @State private var viewModel: NearbySendViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: NearbySendContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: NearbySendViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(
                label: ShareSheetLabel.nearby,
                title: String(localized: "nearbySend.title", defaultValue: "Share Nearby"),
                subtitle: String(
                    localized: "nearbySend.subtitle",
                    defaultValue: "Send configuration to a teammate's Mac nearby. They open Share › Receive Nearby."
                ),
                isExperimental: true
            )
            if let preview = viewModel.preview {
                ShareContentSummaryView(preview: preview)
            }
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
        case .chooseSelection:
            NearbySelectionView(viewModel: viewModel)
        case .browsing:
            NearbyPeerListView(viewModel: viewModel)
        case .connecting:
            NearbyProgressRow(text: String(localized: "nearbySend.connecting", defaultValue: "Connecting…"))
        case .comparing(let sas):
            SASCodeView(sas: sas, isConfirmed: false, isPeerConfirmed: viewModel.isPeerConfirmed) { decision in
                Task { await viewModel.decide(decision) }
            }
        case .authenticating(let sas):
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                SASCodeView(sas: sas, isConfirmed: true, isPeerConfirmed: viewModel.isPeerConfirmed) { _ in }
                if !viewModel.reauth.isAuthorized {
                    ShareReauthView(
                        model: viewModel.reauth,
                        message: String(
                            localized: "nearbySend.reauth.message",
                            defaultValue: "Sending shares values. Use Touch ID or your master password before anything is sent."
                        ),
                        onTouchID: { await viewModel.authenticateWithTouchID() },
                        onPassword: { await viewModel.authenticateWithPassword() }
                    )
                }
            }
        case .awaitingDecision:
            NearbyProgressRow(text: String(
                localized: "nearbySend.awaitingDecision",
                defaultValue: "Waiting for your teammate to review and accept…"
            ))
        case .sending:
            NearbyProgressRow(text: String(
                localized: "nearbySend.sending",
                defaultValue: "Sending… Your teammate confirms the values before anything is imported."
            ))
        case .finished(let outcome):
            SheetCallout(
                systemImage: outcome == .delivered ? "checkmark.circle" : "xmark.circle",
                tint: outcome == .delivered ? Theme.Colors.success : Theme.Colors.subtleText,
                text: message(for: outcome)
            )
        case .failed:
            NearbyFailureView(abort: viewModel.abort, showsInterceptionWarning: viewModel.showsInterceptionWarning)
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            if viewModel.step == .failed || viewModel.isFinished {
                Button(String(localized: "nearby.tryAgain", defaultValue: "Try Again")) {
                    viewModel.tryAgain()
                }
                .fxButtonStyle(.outline, size: .large)
            }
            Spacer()
            switch viewModel.step {
            case .finished, .failed:
                Button(String(localized: "common.done", defaultValue: "Done")) {
                    dismiss()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
            case .chooseSelection:
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "nearbySend.continue", defaultValue: "Continue")) {
                    viewModel.continueWithSelection()
                }
                .fxButtonStyle(.primary, size: .large)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canContinueWithSelection)
            default:
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func message(for outcome: NearbySendOutcome) -> String {
        switch outcome {
        case .delivered:
            String(localized: "nearbySend.done.delivered", defaultValue: "Shared. Your teammate imported the configuration.")
        case .receiverRejected:
            String(localized: "nearbySend.done.rejected", defaultValue: "Your teammate rejected the values. Nothing was imported.")
        case .declined:
            String(localized: "nearbySend.done.declined", defaultValue: "Your teammate declined. Nothing was sent.")
        }
    }
}

/// "What to send" when the sheet opened without a selection: a repository, then the tree.
private struct NearbySelectionView: View {
    let viewModel: NearbySendViewModel
    @State private var repositoryID: RepoID?

    var body: some View {
        let repositoryLabel = String(localized: "nearbySend.repository", defaultValue: "Repository")
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SectionLabel(repositoryLabel)
            Picker(repositoryLabel, selection: $repositoryID) {
                Text(String(localized: "nearbySend.repository.none", defaultValue: "Choose…"))
                    .tag(RepoID?.none)
                ForEach(viewModel.repositories) { repository in
                    Text(verbatim: repository.fullName).tag(RepoID?.some(repository.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: repositoryID) {
                guard let repositoryID else { return }
                Task { await viewModel.chooseRepository(repositoryID) }
            }
            if let tree = viewModel.tree {
                ShareScopeTreeView(tree: tree) { checked, node in
                    viewModel.setChecked(checked, for: node)
                }
            }
        }
    }
}

/// The receivers found on the local network.
private struct NearbyPeerListView: View {
    let viewModel: NearbySendViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if let error = viewModel.networkError {
                InlineErrorView(error: error)
                Button(String(localized: "nearby.tryAgain", defaultValue: "Try Again")) {
                    viewModel.startBrowsing()
                }
                .fxButtonStyle(.outline)
            } else if viewModel.peers.isEmpty {
                NearbyProgressRow(text: String(
                    localized: "nearbySend.searching",
                    defaultValue: "Looking for Macs with Receive Nearby open…"
                ))
            } else {
                SectionLabel(String(localized: "nearbySend.peers", defaultValue: "Nearby Macs"))
                List(viewModel.peers) { peer in
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "laptopcomputer")
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Colors.subtleText)
                            .accessibilityHidden(true)
                        Text(peer.shortLabel)
                            .fxTextStyle(.monoName)
                            .foregroundStyle(Theme.Colors.ink)
                            .lineLimit(1)
                        Spacer()
                        Button(String(localized: "nearbySend.connect", defaultValue: "Connect")) {
                            Task { await viewModel.connect(to: peer) }
                        }
                        .fxButtonStyle(.secondary)
                    }
                    .frame(minHeight: Theme.Layout.tableCellMinHeight)
                    .listRowSeparator(.visible)
                    .listRowSeparatorTint(Theme.Colors.hairline)
                }
                .shareListContainer()
                .frame(height: Theme.Layout.shareListHeight)
                Text(String(
                    localized: "nearbySend.peers.note",
                    defaultValue: "Names appear after connecting. You compare a code before anything is sent."
                ))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
            }
        }
    }
}

/// Why a nearby share stopped, with the interception warning when it applies (§9.4).
struct NearbyFailureView: View {
    let abort: NearbyAbortModel?
    let showsInterceptionWarning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Banner(
                .danger,
                message: abort?.localizedMessage ?? String(
                    localized: "nearby.abort.generic",
                    defaultValue: "The nearby share stopped. Nothing was shared."
                ),
                systemImage: "xmark.octagon"
            )
            if showsInterceptionWarning {
                Banner(.danger, message: NearbyAbortModel.interceptionWarning, systemImage: "exclamationmark.shield")
            }
        }
    }
}
