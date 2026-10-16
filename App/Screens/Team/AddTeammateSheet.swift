import SwiftUI

/// Add Teammate (v0.5.0, T2): people with the sheet open on their Mac, the code to compare, then
/// the outcome. The presenter starts the view model (``AddTeammateViewModel/start()``) and closes
/// it when the sheet goes away.
struct AddTeammateSheet: View {
    let viewModel: AddTeammateViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            SheetHeader(
                label: String(localized: "teammates.add.eyebrow", defaultValue: "Teammates"),
                title: String(localized: "teammates.add.title", defaultValue: "Add Teammate"),
                subtitle: String(
                    localized: "teammates.add.subtitle",
                    defaultValue: "Open Add Teammate on both Macs, choose the other person, and compare the code."
                )
            )
            content
            HStack {
                Spacer()
                Button(closeTitle) {
                    dismiss()
                }
                .fxButtonStyle(isFinished ? .primary : .secondary)
                .keyboardShortcut(isFinished ? .defaultAction : .cancelAction)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: Theme.Layout.addTeammateSheetWidth)
    }

    @ViewBuilder private var content: some View {
        switch viewModel.step {
        case .browsing:
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text(String(localized: "teammates.add.visibleAs", defaultValue: "Visible to people nearby as \(viewModel.displayName)"))
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                        if viewModel.peers.isEmpty {
                            HStack(spacing: Theme.Spacing.small) {
                                ProgressView().controlSize(.small)
                                Text(String(localized: "teammates.add.waiting", defaultValue: "Looking for Macs with Add Teammate open…"))
                                    .fxTextStyle(.callout)
                                    .foregroundStyle(Theme.Colors.mutedText)
                            }
                            .padding(Theme.Spacing.medium)
                        }
                        ForEach(viewModel.peers) { peer in
                            Button {
                                viewModel.pair(with: peer)
                            } label: {
                                HStack {
                                    Text(verbatim: peer.chatDisplayName)
                                        .fxTextStyle(.body)
                                        .foregroundStyle(Theme.Colors.ink)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(Theme.Colors.subtleText)
                                        .accessibilityHidden(true)
                                }
                                .padding(Theme.Spacing.medium)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: Theme.Layout.addTeammateListHeight)
                .fxCardBackground(.container)
                if let error = viewModel.discoveryError {
                    InlineErrorView(error: error)
                }
            }
        case .connecting(let name):
            HStack(spacing: Theme.Spacing.small) {
                ProgressView().controlSize(.small)
                Text(name.map { String(localized: "teammates.add.connecting.named", defaultValue: "Connecting to \($0)…") }
                    ?? String(localized: "teammates.add.connecting", defaultValue: "Someone is connecting…"))
                    .fxTextStyle(.callout)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        case .comparing(let sas):
            SASCodeView(
                sas: sas,
                isConfirmed: viewModel.isCodeConfirmed,
                isPeerConfirmed: viewModel.isPeerCodeConfirmed
            ) { decision in
                viewModel.decide(decision)
            }
        case .paired(let name):
            Banner(.info, message: String(
                localized: "teammates.add.paired",
                defaultValue: "\(name) is now your teammate. You'll see each other nearby and can ping and chat without a code."
            ))
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                Banner(.warning, message: message)
                Button(String(localized: "teammates.add.tryAgain", defaultValue: "Try Again")) {
                    Task { await viewModel.restart() }
                }
                .fxButtonStyle(.outline)
            }
        }
    }

    private var isFinished: Bool {
        if case .paired = viewModel.step { true } else { false }
    }

    private var closeTitle: String {
        isFinished
            ? String(localized: "common.done", defaultValue: "Done")
            : String(localized: "common.cancel", defaultValue: "Cancel")
    }
}
