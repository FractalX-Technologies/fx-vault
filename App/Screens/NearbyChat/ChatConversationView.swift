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
            Divider()
            ChatTranscriptView(viewModel: viewModel)
            Divider()
            ChatComposerView(viewModel: viewModel)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Theme.Colors.success)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: viewModel.peerName ?? String(localized: "chat.peer.unknown", defaultValue: "Nearby Mac"))
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(String(
                    localized: "chat.header.note",
                    defaultValue: "Codes matched. End-to-end encrypted; messages are never saved."
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer()
            Button(String(localized: "chat.end", defaultValue: "End Chat")) {
                Task { await viewModel.endChat() }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
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
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Spacing.xLarge)
                    }
                    ForEach(viewModel.entries) { entry in
                        row(entry)
                            .id(entry.id)
                    }
                }
                .padding(Theme.Spacing.large)
            }
            .onChange(of: viewModel.entries.last?.id) { _, last in
                guard let last else { return }
                withAnimation(Theme.Durations.standardAnimation) {
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

/// One message: sent on the right, received on the left, with the time it was sent or received.
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
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.vertical, Theme.Spacing.small)
                    .background(
                        isSent ? Theme.Colors.accent.opacity(Theme.Opacity.chipBackground) : Theme.Colors.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.large)
                    )
                    .contextMenu {
                        Button(String(localized: "chat.message.copy", defaultValue: "Copy"), action: onCopy)
                    }
                Text(message.date, style: .time)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
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

/// The message field, the remaining length, "Attach secret or variable…" and Send (⌘↩).
private struct ChatComposerView: View {
    let viewModel: NearbyChatViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.draft)
                    .font(Theme.Typography.body)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .frame(height: Theme.Layout.chatComposerHeight)
                    .accessibilityLabel(String(localized: "chat.composer.label", defaultValue: "Message"))
                if viewModel.draft.isEmpty {
                    Text(String(localized: "chat.composer.placeholder", defaultValue: "Message (⌘↩ to send)"))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .padding(.leading, Theme.Spacing.xSmall)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(Theme.Spacing.small)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
            HStack(spacing: Theme.Spacing.medium) {
                Button {
                    viewModel.attach()
                } label: {
                    Label(
                        String(localized: "chat.attach", defaultValue: "Attach secret or variable…"),
                        systemImage: "paperclip"
                    )
                }
                .disabled(!viewModel.canAttach)
                .help(String(
                    localized: "chat.attach.help",
                    defaultValue: "Asks for Touch ID or your master password, then sends the name only. The value is sent only if your teammate saves it."
                ))
                Spacer()
                Text(String(
                    localized: "chat.composer.remaining",
                    defaultValue: "\(viewModel.remainingMessageBytes) left"
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(viewModel.isDraftTooLong ? Theme.Colors.danger : Theme.Colors.textSecondary)
                .monospacedDigit()
                Button(String(localized: "chat.send", defaultValue: "Send")) {
                    Task { await viewModel.send() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!viewModel.canSend)
            }
        }
        .padding(Theme.Spacing.large)
        .onAppear { isFocused = true }
    }
}
