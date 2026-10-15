import SwiftUI
import VaultCore
import VaultData

/// "Attach secret or variable…": confirm it's you (Touch ID or master password), then choose one
/// item. See ``ChatAttachmentPickerViewModel``.
struct ChatAttachmentPickerSheet: View {
    let viewModel: ChatAttachmentPickerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            ShareSheetHeader(
                systemImage: "paperclip",
                title: String(localized: "chat.picker.title", defaultValue: "Attach Secret or Variable"),
                subtitle: String(
                    localized: "chat.picker.subtitle",
                    defaultValue: "Your teammate sees the name, kind and scope. The value is sent only if they save it."
                )
            )
            Divider()
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
            HStack {
                Spacer()
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "chat.picker.send", defaultValue: "Attach")) {
                    Task { await viewModel.send() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canSend)
            }
        }
        .padding(Theme.Spacing.xLarge)
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
            .textFieldStyle(.roundedBorder)
            if let error = viewModel.loadError {
                InlineErrorView(error: error)
            } else if viewModel.sections.isEmpty {
                Text(String(
                    localized: "chat.picker.empty",
                    defaultValue: "No secret or variable with a value matches."
                ))
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(maxWidth: .infinity, minHeight: Theme.Layout.chatPickerListHeight)
            } else {
                List(selection: $viewModel.selectedID) {
                    ForEach(viewModel.sections) { section in
                        Section(sectionTitle(section)) {
                            ForEach(section.items) { item in
                                HStack(spacing: Theme.Spacing.small) {
                                    Image(systemName: item.kind == .secret ? "key.fill" : "textformat")
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                        .accessibilityHidden(true)
                                    Text(verbatim: item.name)
                                        .font(Theme.Typography.monospaced)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(item.kind.editorTitle)
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                }
                                .tag(item.id)
                            }
                        }
                    }
                }
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
