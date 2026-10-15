import SharingKit
import SwiftUI
import VaultCore

/// An attached secret or variable (name, kind, repository/environment) or, since v0.4.0, a whole
/// repository (name and counts). **Never a value.** A received item has "Save to my vault" (the
/// share import preview) and "Dismiss"; a received repository has "Import Into…" (choose one of
/// your repositories, then the preview), "Save as File…" and "Dismiss".
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
                    SectionLabel(kindTitle)
                    Spacer(minLength: Theme.Spacing.small)
                    Text(card.date, style: .time)
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.subtleText)
                }
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: symbol)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .accessibilityHidden(true)
                    Text(verbatim: card.offer.itemName ?? card.offer.repositoryFullName)
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

    private var kindTitle: String {
        card.offer.kind?.editorTitle ?? String(localized: "chat.card.repository.kind", defaultValue: "Repository")
    }

    private var symbol: String {
        switch card.offer.kind {
        case .secret: "key"
        case .variable: "textformat"
        case nil: "book.closed"
        }
    }

    /// `owner/name · production`, `owner/name · Repository`, or for a whole repository its counts.
    private var scopeLine: String {
        if case .configuration(let summary) = card.offer.content {
            // Automatic grammar agreement: "1 environment · 3 secrets · 1 variable".
            let counts = String(AttributedString(
                localized: "chat.card.repository.counts",
                defaultValue: "^[\(summary.environmentNames.count) environment](inflect: true) · ^[\(summary.secretCount) secret](inflect: true) · ^[\(summary.variableCount) variable](inflect: true)"
            ).characters)
            guard summary.valueMissingCount > 0 else { return counts }
            let missing = String(
                localized: "chat.card.repository.valueMissing",
                defaultValue: "\(summary.valueMissingCount) without a value"
            )
            return "\(counts) · \(missing)"
        }
        let scope = card.offer.environmentName
            ?? String(localized: "chat.card.repositoryLevel", defaultValue: "Repository")
        return "\(card.offer.repositoryFullName) · \(scope)"
    }

    private var statusLine: String {
        card.offer.isConfiguration ? configurationStatusLine : itemStatusLine
    }

    /// The status of a whole repository (v0.4.0).
    private var configurationStatusLine: String {
        switch card.status {
        case .awaitingPeer:
            String(
                localized: "chat.card.repository.awaitingPeer",
                defaultValue: "Offered. The values are sent only if your teammate imports it or saves it as a file."
            )
        case .sent:
            String(localized: "chat.card.repository.sent", defaultValue: "Your teammate received it. The values were sent once.")
        case .dismissedByPeer:
            String(
                localized: "chat.card.repository.dismissedByPeer",
                defaultValue: "Not sent. Your teammate dismissed it, or the repository changed since you attached it."
            )
        case .offered:
            String(
                localized: "chat.card.repository.offered",
                defaultValue: "The values are not shown. Import Into… lets you choose one of your repositories and review everything first."
            )
        case .requested:
            String(localized: "chat.card.requested", defaultValue: "Receiving…")
        case .readyToSave:
            String(localized: "chat.card.repository.readyToSave", defaultValue: "Arrived. Import it into one of your repositories, or save it as a file.")
        case .reviewing:
            String(localized: "chat.card.reviewing", defaultValue: "Reviewing…")
        case .savingToFile:
            String(localized: "chat.card.repository.savingToFile", defaultValue: "Saving as a file…")
        case .savedToFile:
            String(localized: "chat.card.repository.savedToFile", defaultValue: "Saved as an encrypted file. You can still import it.")
        case .saved:
            String(localized: "chat.card.saved", defaultValue: "Saved to your vault. Nothing was synced.")
        case .notSaved where card.hasSavedFile:
            String(
                localized: "chat.card.repository.notImportedSavedFile",
                defaultValue: "Saved as an encrypted file, not imported. The values in this chat were wiped."
            )
        case .notSaved:
            String(localized: "chat.card.repository.notSaved", defaultValue: "Not imported. The values were wiped.")
        case .dismissed:
            String(localized: "chat.card.dismissed", defaultValue: "Dismissed. Nothing was sent.")
        case .withdrawn:
            String(localized: "chat.card.withdrawn", defaultValue: "Withdrawn by your teammate.")
        }
    }

    private var itemStatusLine: String {
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
        case .reviewing, .savingToFile:
            String(localized: "chat.card.reviewing", defaultValue: "Reviewing…")
        case .saved, .savedToFile:
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
        if card.offer.isConfiguration {
            configurationActions
        } else {
            itemActions
        }
    }

    /// Import Into…, Save as File… and Dismiss for a received repository (v0.4.0).
    @ViewBuilder
    private var configurationActions: some View {
        if card.isAwaitingDecision || card.canReview {
            HStack(spacing: Theme.Spacing.small) {
                Button(String(localized: "chat.card.repository.importInto", defaultValue: "Import Into…")) {
                    Task { await viewModel.handleConfiguration(card.id, .importInto) }
                }
                .fxButtonStyle(.primary)
                if card.isAwaitingDecision || card.canSaveAsFile {
                    Button(String(localized: "chat.card.repository.saveAsFile", defaultValue: "Save as File…")) {
                        Task { await viewModel.handleConfiguration(card.id, .saveAsFile) }
                    }
                    .fxButtonStyle(.secondary)
                }
                if card.isAwaitingDecision {
                    Button(String(localized: "chat.card.dismiss", defaultValue: "Dismiss")) {
                        Task { await viewModel.dismiss(card.id) }
                    }
                    .fxButtonStyle(.ghost)
                }
            }
            .padding(.top, Theme.Spacing.xSmall)
        } else if card.status == .requested {
            ProgressView()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var itemActions: some View {
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
