import SwiftUI
import VaultCore
import VaultData

/// "Attach secret or variable…": confirm it's you (Touch ID or master password), then choose one
/// item. See ``ChatAttachmentPickerViewModel``.
struct ChatAttachmentPickerSheet: View {
    let viewModel: ChatAttachmentPickerViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(
                label: ShareSheetLabel.nearbyChat,
                title: String(localized: "chat.picker.title", defaultValue: "Attach Secret or Variable"),
                subtitle: String(
                    localized: "chat.picker.subtitle",
                    defaultValue: "Your teammate sees the name, kind and scope. The value is sent only if they save it."
                )
            )
            switch viewModel.step {
            case .authenticating:
                ShareReauthView(
                    model: viewModel.reauth,
                    message: String(
                        localized: "chat.picker.reauth",
                        defaultValue: "Attaching from your vault needs Touch ID or your master password."
                    ),
                    onTouchID: { await viewModel.authenticateWithTouchID() },
                    onPassword: { await viewModel.authenticateWithPassword() }
                )
            case .choosing, .sending:
                chooser
            }
            Spacer(minLength: 0)
            HStack(spacing: Theme.Spacing.mediumMinus) {
                Spacer()
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "chat.picker.send", defaultValue: "Attach")) {
                    Task { await viewModel.send() }
                }
                .fxButtonStyle(.primary, size: .large)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canSend)
            }
        }
        .fxSheetContent()
        .frame(width: Theme.Layout.chatPickerWidth)
        .task { await viewModel.begin() }
        .onDisappear { viewModel.close() }
    }

    @ViewBuilder
    private var chooser: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            TextField(
                String(localized: "chat.picker.search", defaultValue: "Search by name, repository or environment"),
                text: $viewModel.query
            )
            .focused($isSearchFocused)
            .fxInputField(.pill, isFocused: isSearchFocused)
            if let error = viewModel.loadError {
                InlineErrorView(error: error)
            } else if viewModel.sections.isEmpty {
                Text(String(
                    localized: "chat.picker.empty",
                    defaultValue: "No secret or variable with a value matches."
                ))
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .frame(maxWidth: .infinity, minHeight: Theme.Layout.chatPickerListHeight)
            } else {
                List(selection: $viewModel.selectedID) {
                    ForEach(viewModel.sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                HStack(spacing: Theme.Spacing.small) {
                                    Image(systemName: item.kind == .secret ? "key" : "textformat")
                                        .font(Theme.Typography.callout)
                                        .foregroundStyle(Theme.Colors.onSelectionSecondary)
                                        .accessibilityHidden(true)
                                    Text(verbatim: item.name)
                                        .fxTextStyle(.monoName)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    // Hierarchical styles, so the row still reads on the selection highlight.
                                    Text(item.kind.editorTitle)
                                        .fxTextStyle(.caption)
                                        .foregroundStyle(Theme.Colors.onSelectionSecondary)
                                }
                                .frame(minHeight: Theme.Layout.scopeRowHeight)
                                .tag(item.id)
                            }
                        } header: {
                            Text(verbatim: sectionTitle(section))
                                .fxTextStyle(.monoMeta)
                                .foregroundStyle(Theme.Colors.subtleText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .shareListContainer()
                .frame(height: Theme.Layout.chatPickerListHeight)
            }
        }
    }

    private func sectionTitle(_ section: ChatPickerSectionModel) -> String {
        let scope = section.environmentName
            ?? String(localized: "chat.card.repositoryLevel", defaultValue: "Repository")
        return "\(section.repositoryFullName) · \(scope)"
    }
}
