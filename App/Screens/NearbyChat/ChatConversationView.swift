import SharingKit
import SwiftUI
import VaultCore

/// The verified chat: who you're talking to, the transcript (bubbles with times and attachment
/// cards) and the message field (⌘↩ sends).
struct ChatConversationView: View {
    let viewModel: NearbyChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            HairlineDivider()
            ChatTranscriptView(viewModel: viewModel)
            HairlineDivider()
            ChatComposerView(viewModel: viewModel)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "lock.fill")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                HStack(spacing: Theme.Spacing.small) {
                    Text(verbatim: viewModel.peerName ?? String(localized: "chat.peer.unknown", defaultValue: "Nearby Mac"))
                        .fxTextStyle(.headline)
                        .foregroundStyle(Theme.Colors.ink)
                    if viewModel.verifiedTeammateName != nil {
                        StatusChip(title: String(localized: "chat.header.teammate", defaultValue: "Teammate"), tone: .success)
                    }
                }
                Text(viewModel.verifiedTeammateName == nil
                    ? String(
                        localized: "chat.header.note",
                        defaultValue: "Codes matched. End-to-end encrypted; messages are never saved."
                    )
                    : String(
                        localized: "chat.header.note.teammate",
                        defaultValue: "Your teammate's Mac proved who it is. End-to-end encrypted; messages are never saved."
                    ))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
            }
            Spacer()
            Button(String(localized: "chat.end", defaultValue: "End Chat")) {
                Task { await viewModel.endChat() }
            }
            .fxButtonStyle(.outline)
        }
        .padding(.horizontal, Theme.Spacing.xLarge)
        .padding(.vertical, Theme.Spacing.medium)
    }
}

/// Messages and attachment cards, newest at the bottom.
private struct ChatTranscriptView: View {
    let viewModel: NearbyChatViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    if viewModel.entries.isEmpty {
                        Text(String(
                            localized: "chat.empty",
                            defaultValue: "Say hello. You can also attach a secret or variable; it is sent only if your teammate saves it."
                        ))
                        .fxTextStyle(.callout)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Spacing.xLarge)
                    }
                    ForEach(viewModel.entries) { entry in
                        row(entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xLarge)
                .padding(.vertical, Theme.Spacing.large)
            }
            .onChange(of: viewModel.entries.last?.id) { _, last in
                guard let last else { return }
                withAnimation(Theme.Durations.interactionAnimation) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: ChatEntryModel) -> some View {
        switch entry {
        case .message(let message):
            ChatBubbleView(message: message) {
                viewModel.copy(message)
            }
        case .attachment(let id):
            if let card = viewModel.cards[id] {
                ChatAttachmentCardView(card: card, viewModel: viewModel)
            }
        }
    }
}

/// One message: sent on the right (ink fill, ground text), received on the left (`surface2`),
/// with the time it was sent or received in Geist Mono.
/// The text is not selectable: Copy (context menu) goes through `ClipboardManager`, so a token
/// pasted into the chat is concealed, stays on this Mac and is cleared like a copied value.
private struct ChatBubbleView: View {
    let message: ChatMessageModel
    let onCopy: () -> Void

    private var isSent: Bool {
        message.direction == .sent
    }

    var body: some View {
        HStack {
            if isSent {
                Spacer(minLength: Theme.Spacing.xxLarge)
            }
            VStack(alignment: isSent ? .trailing : .leading, spacing: Theme.Spacing.xSmall) {
                Text(verbatim: message.text)
                    .fxTextStyle(.body)
                    .foregroundStyle(isSent ? Theme.Colors.onInk : Theme.Colors.ink)
                    .padding(.horizontal, Theme.Spacing.large)
                    .padding(.vertical, Theme.Spacing.mediumMinus)
                    .background(
                        isSent ? Theme.Colors.ink : Theme.Colors.surface2,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous)
                    )
                    .contextMenu {
                        Button(String(localized: "chat.message.copy", defaultValue: "Copy"), action: onCopy)
                    }
                Text(message.date, style: .time)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.subtleText)
            }
            .frame(maxWidth: Theme.Layout.chatBubbleMaxWidth, alignment: isSent ? .trailing : .leading)
            if !isSent {
                Spacer(minLength: Theme.Spacing.xxLarge)
            }
        }
        .frame(maxWidth: .infinity, alignment: isSent ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The message field, the remaining length, "Attach…" (a secret, a variable or, since v0.4.0, a
/// whole repository) and Send (⌘↩).
private struct ChatComposerView: View {
    let viewModel: NearbyChatViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.draft)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.ink)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .frame(height: Theme.Layout.chatComposerHeight)
                    .accessibilityLabel(String(localized: "chat.composer.label", defaultValue: "Message"))
                if viewModel.draft.isEmpty {
                    Text(String(localized: "chat.composer.placeholder", defaultValue: "Message (⌘↩ to send)"))
                        .fxTextStyle(.body)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .padding(.leading, Theme.Spacing.xSmall)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, Theme.Spacing.small)
            .fxInputField(.rounded, isFocused: isFocused, isInvalid: viewModel.isDraftTooLong)
            HStack(spacing: Theme.Spacing.medium) {
                Button {
                    viewModel.attach()
                } label: {
                    Label(
                        String(localized: "chat.attach.any", defaultValue: "Attach…"),
                        systemImage: "paperclip"
                    )
                }
                .fxButtonStyle(.ghost)
                .disabled(!viewModel.canAttach)
                .help(String(
                    localized: "chat.attach.any.help",
                    defaultValue: "Attach a secret, a variable or a whole repository. Asks for Touch ID or your master password, then sends names only. Values are sent only if your teammate saves them."
                ))
                Spacer()
                Text(String(
                    localized: "chat.composer.remaining",
                    defaultValue: "\(viewModel.remainingMessageBytes) left"
                ))
                .fxTextStyle(.monoMeta)
                .foregroundStyle(viewModel.isDraftTooLong ? Theme.Colors.danger : Theme.Colors.subtleText)
                Button(String(localized: "chat.send", defaultValue: "Send")) {
                    Task { await viewModel.send() }
                }
                .fxButtonStyle(.primary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!viewModel.canSend)
            }
        }
        .padding(.horizontal, Theme.Spacing.xLarge)
        .padding(.vertical, Theme.Spacing.large)
        .onAppear { isFocused = true }
    }
}
