import SharingKit
import SwiftUI

/// The "Nearby" column: Macs with Nearby Chat open, by the name they advertise (unverified).
/// Connecting is possible only while browsing.
struct ChatPeerListView: View {
    let viewModel: NearbyChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SectionLabel(String(localized: "chat.peers.title", defaultValue: "Nearby"))
            if let error = viewModel.discoveryError ?? viewModel.visibilityError {
                InlineErrorView(error: error)
                Button(String(localized: "nearby.tryAgain", defaultValue: "Try Again")) {
                    Task { await viewModel.start() }
                }
                .fxButtonStyle(.outline)
            } else if viewModel.step != .browsing {
                Text(String(
                    localized: "chat.peers.busy",
                    defaultValue: "You're in a chat. Nobody else can find or join you until it ends."
                ))
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
            } else if viewModel.peers.isEmpty {
                NearbyProgressRow(text: String(
                    localized: "chat.peers.searching",
                    defaultValue: "Looking for Macs with Nearby Chat open…"
                ))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                        ForEach(viewModel.peers) { peer in
                            ChatPeerRow(name: peer.chatDisplayName) {
                                Task { await viewModel.connect(to: peer) }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Text(String(
                localized: "chat.peers.note",
                defaultValue: "Names are what each Mac says it is. The code you compare next proves who you're talking to."
            ))
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.mutedText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Spacing.large)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// One nearby Mac: an avatar circle, the advertised name and "Chat".
private struct ChatPeerRow: View {
    let name: String
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "person.fill")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .frame(width: Theme.Layout.avatarSize, height: Theme.Layout.avatarSize)
                .background(Theme.Colors.card, in: Circle())
                .overlay(Circle().strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline))
                .accessibilityHidden(true)
            Text(verbatim: name)
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Spacing.xSmall)
            Button(String(localized: "chat.peers.connect", defaultValue: "Chat"), action: onConnect)
                .fxButtonStyle(.secondary)
        }
        .padding(.vertical, Theme.Spacing.xSmall)
        .frame(minHeight: Theme.Layout.sidebarRowHeight)
    }
}
