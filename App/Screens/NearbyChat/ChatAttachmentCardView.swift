import SharingKit
import SwiftUI
import VaultCore

/// An attached secret or variable: name, kind and repository/environment. **Never a value.**
/// Received offers have "Save to my vault" (the share import preview) and "Dismiss".
struct ChatAttachmentCardView: View {
    let card: ChatAttachmentCardModel
    let viewModel: NearbyChatViewModel

    private var isSent: Bool {
        card.direction == .sent
    }

    var body: some View {
        HStack {
            if isSent {
                Spacer(minLength: Theme.Spacing.xxLarge)
            }
            Card(padding: Theme.Spacing.largePlus, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.small) {
                    SectionLabel(card.offer.kind.editorTitle)
                    Spacer(minLength: Theme.Spacing.small)
                    Text(card.date, style: .time)
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.subtleText)
                }
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: card.offer.kind == .secret ? "key" : "textformat")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .accessibilityHidden(true)
                    Text(verbatim: card.offer.itemName)
                        .fxTextStyle(.mono)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(verbatim: scopeLine)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusLine)
                    .fxTextStyle(.callout)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
            .frame(maxWidth: Theme.Layout.chatBubbleMaxWidth, alignment: .leading)
            if !isSent {
                Spacer(minLength: Theme.Spacing.xxLarge)
            }
        }
        .frame(maxWidth: .infinity, alignment: isSent ? .trailing : .leading)
    }

    /// `owner/name · production` or `owner/name · Repository`.
    private var scopeLine: String {
        let scope = card.offer.environmentName
            ?? String(localized: "chat.card.repositoryLevel", defaultValue: "Repository")
        return "\(card.offer.repositoryFullName) · \(scope)"
    }

    private var statusLine: String {
        switch card.status {
        case .awaitingPeer:
            String(
                localized: "chat.card.awaitingPeer",
                defaultValue: "Offered. The value is sent only if your teammate saves it."
            )
        case .sent:
            String(localized: "chat.card.sent", defaultValue: "Your teammate saved it. The value was sent once.")
        case .dismissedByPeer:
            String(localized: "chat.card.dismissedByPeer", defaultValue: "Not sent. Your teammate dismissed it, or the item changed.")
        case .offered:
            String(
                localized: "chat.card.offered",
                defaultValue: "The value is not shown. Saving lets you review it before anything is imported."
            )
        case .requested:
            String(localized: "chat.card.requested", defaultValue: "Receiving…")
        case .readyToSave:
            String(localized: "chat.card.readyToSave", defaultValue: "Arrived. Review it to save it to your vault.")
        case .reviewing:
            String(localized: "chat.card.reviewing", defaultValue: "Reviewing…")
        case .saved:
            String(localized: "chat.card.saved", defaultValue: "Saved to your vault. Nothing was synced.")
        case .notSaved:
            String(localized: "chat.card.notSaved", defaultValue: "Not saved. The value was wiped.")
        case .dismissed:
            String(localized: "chat.card.dismissed", defaultValue: "Dismissed. Nothing was sent.")
        case .withdrawn:
            String(localized: "chat.card.withdrawn", defaultValue: "Withdrawn by your teammate.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if card.isAwaitingDecision {
            HStack(spacing: Theme.Spacing.small) {
                Button(String(localized: "chat.card.save", defaultValue: "Save to my vault")) {
                    Task { await viewModel.save(card.id) }
                }
                .fxButtonStyle(.primary)
                Button(String(localized: "chat.card.dismiss", defaultValue: "Dismiss")) {
                    Task { await viewModel.dismiss(card.id) }
                }
                .fxButtonStyle(.ghost)
            }
            .padding(.top, Theme.Spacing.xSmall)
        } else if card.canReview {
            Button(String(localized: "chat.card.review", defaultValue: "Review…")) {
                viewModel.review(card.id)
            }
            .fxButtonStyle(.primary)
            .padding(.top, Theme.Spacing.xSmall)
        } else if card.status == .requested {
            ProgressView()
                .controlSize(.small)
        }
    }
}
