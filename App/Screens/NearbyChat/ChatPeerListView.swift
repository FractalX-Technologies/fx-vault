import SharingKit
import SwiftUI

/// The "Nearby" column: Macs with Nearby Chat open, by the name they advertise (unverified).
/// Connecting is possible only while browsing.
struct ChatPeerListView: View {
    let viewModel: NearbyChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(String(localized: "chat.peers.title", defaultValue: "Nearby"))
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.textPrimary)
            if let error = viewModel.discoveryError ?? viewModel.visibilityError {
                InlineErrorView(error: error)
                Button(String(localized: "nearby.tryAgain", defaultValue: "Try Again")) {
                    Task { await viewModel.start() }
                }
            } else if viewModel.step != .browsing {
                Text(String(
                    localized: "chat.peers.busy",
                    defaultValue: "You're in a chat. Nobody else can find or join you until it ends."
                ))
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
            } else if viewModel.peers.isEmpty {
                NearbyProgressRow(text: String(
                    localized: "chat.peers.searching",
                    defaultValue: "Looking for Macs with Nearby Chat open…"
                ))
            } else {
                List(viewModel.peers) { peer in
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .accessibilityHidden(true)
                        Text(verbatim: peer.chatDisplayName)
                            .font(Theme.Typography.body)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: Theme.Spacing.xSmall)
                        Button(String(localized: "chat.peers.connect", defaultValue: "Chat")) {
                            Task { await viewModel.connect(to: peer) }
                        }
                        .controlSize(.small)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
            Spacer(minLength: 0)
            Text(String(
                localized: "chat.peers.note",
                defaultValue: "Names are what each Mac says it is. The code you compare next proves who you're talking to."
            ))
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.large)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
