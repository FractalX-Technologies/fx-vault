import SwiftUI
import VaultCore
import VaultData

/// "Attach…": confirm it's you (Touch ID or master password), then choose one item, (v0.4.0) a
/// whole repository or (v0.7.0) a folder. See ``ChatAttachmentPickerViewModel``.
struct ChatAttachmentPickerSheet: View {
    let viewModel: ChatAttachmentPickerViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(label: ShareSheetLabel.nearbyChat, title: title, subtitle: subtitle)
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

    private var title: String {
        switch viewModel.mode {
        case .item: String(localized: "chat.picker.title", defaultValue: "Attach Secret or Variable")
        case .repository: String(localized: "chat.picker.repository.title", defaultValue: "Attach a Whole Repository")
        case .folder: String(localized: "chat.picker.folder.title", defaultValue: "Attach a Folder")
        }
    }

    private var subtitle: String {
        switch viewModel.mode {
        case .item:
            String(
                localized: "chat.picker.subtitle",
                defaultValue: "Your teammate sees the name, kind and scope. The value is sent only if they save it."
            )
        case .repository:
            String(
                localized: "chat.picker.repository.subtitle",
                defaultValue: "The repository level and every environment with its branch rules. Your teammate sees names and counts; the values are sent only if they import it or save it as a file."
            )
        case .folder:
            String(
                localized: "chat.picker.folder.subtitle",
                defaultValue: "Every secret and variable of the folder. Your teammate sees its name and counts; the values are sent only if they save it. They get their own copy: later changes are not sent."
            )
        }
    }

    @ViewBuilder
    private var chooser: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SegmentedPill(
                selection: $viewModel.mode,
                segments: [
                    .init(value: .item, title: String(localized: "chat.picker.mode.item", defaultValue: "Secret or Variable")),
                    .init(value: .repository, title: String(localized: "chat.picker.mode.repository", defaultValue: "Whole Repository")),
                    .init(value: .folder, title: FolderCopy.eyebrow),
                ],
                accessibilityLabel: String(localized: "chat.picker.mode", defaultValue: "What to attach")
            )
            .fixedSize()
            TextField(searchPrompt, text: $viewModel.query)
            .focused($isSearchFocused)
            .fxInputField(.pill, isFocused: isSearchFocused)
            switch viewModel.mode {
            case .item:
                itemList
            case .repository:
                repositoryList
            case .folder:
                folderList
            }
        }
    }

    private var searchPrompt: String {
        switch viewModel.mode {
        case .item: String(localized: "chat.picker.search", defaultValue: "Search by name, repository or environment")
        case .repository: String(localized: "chat.picker.repository.search", defaultValue: "Search repositories")
        case .folder: String(localized: "chat.picker.folder.search", defaultValue: "Search folders")
        }
    }

    /// The folders that hold something (v0.7.0), or why the teammate cannot receive one.
    @ViewBuilder
    private var folderList: some View {
        @Bindable var viewModel = viewModel
        if !viewModel.acceptsFolders {
            SheetCallout(
                systemImage: "arrow.down.circle",
                tint: Theme.Colors.warning,
                text: String(
                    localized: "chat.picker.folder.peerNeedsUpdate",
                    defaultValue: "Your teammate's FX Vault cannot receive a folder yet. Ask them to update to FX Vault 0.7 or later, then start a new chat."
                )
            )
        } else if let error = viewModel.loadError {
            InlineErrorView(error: error)
        } else if viewModel.matchingFolders.isEmpty {
            Text(String(localized: "chat.picker.folder.empty", defaultValue: "No folder with secrets or variables matches."))
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .frame(maxWidth: .infinity, minHeight: Theme.Layout.chatPickerListHeight)
        } else {
            List(selection: $viewModel.selectedFolderID) {
                ForEach(viewModel.matchingFolders) { folder in
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "folder")
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Colors.onSelectionSecondary)
                            .accessibilityHidden(true)
                        Text(verbatim: folder.name)
                            .fxTextStyle(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(FolderCopy.counts(secrets: folder.secretCount, variables: folder.variableCount))
                            .fxTextStyle(.caption)
                            .foregroundStyle(Theme.Colors.onSelectionSecondary)
                    }
                    .frame(minHeight: Theme.Layout.scopeRowHeight)
                    .tag(folder.id)
                }
            }
            .shareListContainer()
            .frame(height: Theme.Layout.chatPickerListHeight)
        }
    }

    @ViewBuilder
    private var repositoryList: some View {
        @Bindable var viewModel = viewModel
        if !viewModel.acceptsRepositories {
            SheetCallout(
                systemImage: "arrow.down.circle",
                tint: Theme.Colors.warning,
                text: String(
                    localized: "chat.picker.repository.peerNeedsUpdate",
                    defaultValue: "Your teammate's FX Vault cannot receive a whole repository yet. Ask them to update to FX Vault 0.4 or later, then start a new chat."
                )
            )
        } else if let error = viewModel.loadError {
            InlineErrorView(error: error)
        } else if viewModel.matchingRepositories.isEmpty {
            Text(String(localized: "chat.picker.repository.empty", defaultValue: "No repository with environments, secrets or variables matches."))
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .frame(maxWidth: .infinity, minHeight: Theme.Layout.chatPickerListHeight)
        } else {
            List(selection: $viewModel.selectedRepositoryID) {
                ForEach(viewModel.matchingRepositories) { repository in
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "book.closed")
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Colors.onSelectionSecondary)
                            .accessibilityHidden(true)
                        Text(verbatim: repository.fullName)
                            .fxTextStyle(.monoName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        // Automatic grammar agreement: "1 environment · 4 items".
                        Text(String(AttributedString(
                            localized: "chat.picker.repository.counts",
                            defaultValue: "^[\(repository.environmentCount) environment](inflect: true) · ^[\(repository.itemCount) item](inflect: true)"
                        ).characters))
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.onSelectionSecondary)
                    }
                    .frame(minHeight: Theme.Layout.scopeRowHeight)
                    .tag(repository.id)
                }
            }
            .shareListContainer()
            .frame(height: Theme.Layout.chatPickerListHeight)
        }
    }

    @ViewBuilder
    private var itemList: some View {
        @Bindable var viewModel = viewModel
        Group {
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
