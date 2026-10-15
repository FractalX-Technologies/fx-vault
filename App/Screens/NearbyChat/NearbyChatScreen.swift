import SharingKit
import SwiftUI

/// Window › Nearby Chat (experimental): nearby people on the left, then the code comparison and
/// the conversation on the right. See ``NearbyChatViewModel`` for the rules (visible only while
/// open, ephemeral, wiped on close, lock, sleep or disconnect).
///
/// The window's own scene (`SceneID.nearbyChat`), not a main-window sheet. It is never restored
/// at launch.
struct NearbyChatScreen: View {
    let app: AppViewModel
    @State private var viewModel: NearbyChatViewModel

    init(app: AppViewModel) {
        self.app = app
        _viewModel = State(initialValue: app.makeNearbyChatViewModel())
    }

    /// Shows an existing view model (previews and the visual snapshot tests).
    init(app: AppViewModel, viewModel: NearbyChatViewModel) {
        self.app = app
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 0) {
            NearbyChatHeader(isVisible: viewModel.isVisible, displayName: viewModel.displayName)
            HairlineDivider()
            content
        }
        .frame(
            minWidth: Theme.Layout.chatWindowMinWidth,
            maxWidth: .infinity,
            minHeight: Theme.Layout.chatWindowMinHeight,
            maxHeight: .infinity
        )
        .background(Theme.Colors.ground)
        .background(WindowAccessor { window in
            window.isRestorable = false
        })
        .task { await viewModel.start() }
        .onDisappear { viewModel.close() }
        .onChange(of: app.phase) {
            Task { await viewModel.refreshAvailability() }
        }
        .onChange(of: viewModel.isNearbyAvailable) {
            Task { await viewModel.refreshAvailability() }
        }
        .sheet(item: $viewModel.picker, onDismiss: viewModel.pickerDismissed) { picker in
            ChatAttachmentPickerSheet(viewModel: picker)
        }
        .sheet(item: $viewModel.saveSheet, onDismiss: viewModel.saveSheetDismissed) { save in
            ChatSaveSheet(viewModel: save)
        }
        .sheet(isPresented: fileSheetBinding) {
            if let file = viewModel.fileSheet {
                ShareExportScreen(viewModel: file)
            }
        }
        .errorAlert($viewModel.alert)
    }

    /// "Save as File…" of a received repository (v0.4.0; the view model is not `Identifiable`).
    private var fileSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.fileSheet != nil },
            set: { if !$0 { viewModel.fileSheetDismissed() } }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .locked:
            EmptyStateView(
                systemImage: "lock",
                title: String(localized: "chat.locked.title", defaultValue: "Unlock FX Vault to chat"),
                message: String(
                    localized: "chat.locked.message",
                    defaultValue: "Nearby Chat works only while your vault is unlocked, and ends when it locks."
                )
            ) {
                openVaultButton
            }
        case .unavailable:
            EmptyStateView(
                systemImage: "wifi.slash",
                title: String(localized: "chat.unavailable.title", defaultValue: "Turn on Wi-Fi to chat nearby"),
                message: String(
                    localized: "chat.unavailable.message",
                    defaultValue: "Nearby Chat needs Wi-Fi turned on, or a network cable. You don't need to join a network or have internet."
                )
            )
        default:
            HStack(spacing: 0) {
                ChatPeerListView(viewModel: viewModel)
                    .frame(width: Theme.Layout.chatPeerListWidth)
                    .background(Theme.Colors.surface)
                HairlineDivider(axis: .vertical)
                conversation
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var conversation: some View {
        switch viewModel.step {
        case .browsing:
            EmptyStateView(
                systemImage: "bubble.left.and.bubble.right",
                title: String(localized: "chat.browsing.title", defaultValue: "Chat with a teammate nearby"),
                message: String(
                    localized: "chat.browsing.message",
                    defaultValue: "Choose someone on the left, or wait for them to choose you. You compare a code first; messages are end-to-end encrypted and never saved."
                )
            )
        case .connecting(let peerName):
            VStack(spacing: Theme.Spacing.large) {
                NearbyProgressRow(text: peerName.map {
                    String(localized: "chat.connecting.named", defaultValue: "Connecting with \($0)…")
                } ?? String(localized: "chat.connecting", defaultValue: "Connecting…"))
                cancelButton
            }
            .padding(Theme.Spacing.xLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .comparing(let sas):
            VStack(spacing: Theme.Spacing.xLarge) {
                SASCodeView(
                    sas: sas,
                    isConfirmed: viewModel.isCodeConfirmed,
                    isPeerConfirmed: viewModel.isPeerCodeConfirmed
                ) { decision in
                    Task { await viewModel.decide(decision) }
                }
                cancelButton
            }
            .padding(Theme.Spacing.xLarge)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .chatting:
            ChatConversationView(viewModel: viewModel)
        case .ended(let end):
            ChatEndedView(end: end, isVaultUnlocked: viewModel.isVaultUnlocked) {
                Task { await viewModel.start() }
            } onOpenVault: {
                app.requestMainWindow()
            }
        case .locked, .unavailable:
            EmptyView()
        }
    }

    private var cancelButton: some View {
        Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
            Task { await viewModel.cancelConnection() }
        }
        .fxButtonStyle(.secondary, size: .large)
    }

    private var openVaultButton: some View {
        Button(String(localized: "chat.openVault", defaultValue: "Open FX Vault")) {
            app.requestMainWindow()
        }
        .fxButtonStyle(.primary, size: .large)
    }
}

/// "Nearby Chat", the Experimental badge and whether this Mac is visible right now.
private struct NearbyChatHeader: View {
    let isVisible: Bool
    let displayName: String

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.medium) {
            SheetHeader(
                label: nil,
                title: String(localized: "chat.title", defaultValue: "Nearby Chat"),
                subtitle: String(
                    localized: "chat.subtitle",
                    defaultValue: "End-to-end encrypted, 1:1, nothing saved. Works over Wi-Fi without a shared network."
                ),
                isExperimental: true,
                titleStyle: .title2
            )
            Spacer(minLength: Theme.Spacing.large)
            ChatVisibilityIndicator(isVisible: isVisible, displayName: displayName)
        }
        .padding(.horizontal, Theme.Spacing.xLarge)
        .padding(.vertical, Theme.Spacing.largePlus)
    }
}

/// "You're visible to nearby Macs as <name>" (brand dot) or "Not visible to nearby Macs"
/// (hollow dot), in a hairline pill.
struct ChatVisibilityIndicator: View {
    let isVisible: Bool
    let displayName: String

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Circle()
                .fill(isVisible ? Theme.Colors.brand : Theme.Colors.ground)
                .overlay {
                    if !isVisible {
                        Circle().strokeBorder(Theme.Colors.subtleText, lineWidth: Theme.Stroke.hairline)
                    }
                }
                .frame(width: Theme.Layout.bannerDotSize, height: Theme.Layout.bannerDotSize)
                .accessibilityHidden(true)
            Text(isVisible
                ? String(localized: "chat.visible", defaultValue: "You're visible to nearby Macs as \(displayName)")
                : String(localized: "chat.notVisible", defaultValue: "Not visible to nearby Macs"))
                .fxTextStyle(.caption)
                .foregroundStyle(isVisible ? Theme.Colors.ink : Theme.Colors.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, Theme.Layout.chipPaddingHorizontal)
        .frame(height: Theme.Layout.chipHeight)
        .background(Theme.Colors.card, in: .pill)
        .overlay(Capsule.pill.strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline))
        .animation(Theme.Durations.interactionAnimation, value: isVisible)
        .accessibilityElement(children: .combine)
        .help(isVisible
            ? String(
                localized: "chat.visible.help",
                defaultValue: "Macs nearby with Nearby Chat open see this name until you start a chat or close this window. Change it in Settings › General."
            )
            : String(
                localized: "chat.notVisible.help",
                defaultValue: "Nobody can find this Mac now. Nearby Macs see you only while this window lists people."
            ))
    }
}

/// "Conversation ended. Nothing was saved." with the reason and what to do next.
private struct ChatEndedView: View {
    let end: NearbyChatEndModel
    let isVaultUnlocked: Bool
    let onStartAgain: () -> Void
    let onOpenVault: () -> Void

    var body: some View {
        EmptyStateView(
            systemImage: "bubble.left.and.exclamationmark.bubble.right",
            title: String(localized: "chat.ended.title", defaultValue: "Conversation ended. Nothing was saved."),
            message: detail
        ) {
            VStack(spacing: Theme.Spacing.medium) {
                if end.savedAttachmentCount > 0 {
                    ShareNoteView(
                        systemImage: "checkmark.circle",
                        text: end.savedAttachmentCount == 1
                            ? String(
                                localized: "chat.ended.savedOne",
                                defaultValue: "The item you saved stays in your vault."
                            )
                            : String(
                                localized: "chat.ended.saved",
                                defaultValue: "\(end.savedAttachmentCount) items you saved stay in your vault."
                            ),
                        tint: Theme.Colors.success
                    )
                }
                if end.showsInterceptionWarning {
                    ShareNoteView(
                        systemImage: "exclamationmark.shield",
                        text: NearbyAbortModel.chatInterceptionWarning,
                        tint: Theme.Colors.danger
                    )
                }
                if isVaultUnlocked {
                    Button(String(localized: "chat.startAgain", defaultValue: "Start New Chat"), action: onStartAgain)
                        .fxButtonStyle(.primary, size: .large)
                } else {
                    Button(String(localized: "chat.openVault", defaultValue: "Open FX Vault"), action: onOpenVault)
                        .fxButtonStyle(.primary, size: .large)
                }
            }
        }
    }

    private var detail: String {
        let wiped = String(
            localized: "chat.ended.wiped",
            defaultValue: "The messages existed only in memory and are gone."
        )
        let reason: String = switch end.reason {
        case .peerLeft:
            end.peerName.map {
                String(localized: "chat.ended.peerLeft.named", defaultValue: "\($0) ended the chat.")
            } ?? String(localized: "chat.ended.peerLeft", defaultValue: "The other person ended the chat.")
        case .endedHere:
            String(localized: "chat.ended.here", defaultValue: "You ended the chat.")
        case .locked:
            String(localized: "chat.ended.locked", defaultValue: "FX Vault locked.")
        case .aborted(let abort):
            abort.chatMessage
        }
        return "\(reason) \(wiped)"
    }
}
