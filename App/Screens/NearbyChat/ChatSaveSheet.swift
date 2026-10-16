import SharingKit
import SwiftUI
import VaultCore
import VaultData

/// "Save to my vault": the share import preview of a secret or variable received in chat
/// (chips, Keep mine for differences, replay and repository checks), then Import. See
/// ``ChatSaveViewModel``.
struct ChatSaveSheet: View {
    let viewModel: ChatSaveViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(
                label: ShareSheetLabel.nearbyChat,
                title: viewModel.isFolder
                    ? String(localized: "chat.save.folder.title", defaultValue: "Save a Folder")
                    : viewModel.isConfiguration
                    ? String(localized: "chat.save.repository.title", defaultValue: "Import Into a Repository")
                    : String(localized: "chat.save.title", defaultValue: "Save to My Vault"),
                subtitle: viewModel.step == .choosingFolderDestination
                    ? String(
                        localized: "chat.save.folder.subtitle",
                        defaultValue: "\(viewModel.itemName), received in Nearby Chat. Save it as a folder, or import its items into one of your repositories."
                    )
                    : viewModel.step == .choosingTarget
                    ? String(
                        localized: "chat.save.repository.subtitle",
                        defaultValue: "\(viewModel.itemName), received in Nearby Chat. Choose one of your repositories, then review everything before it is imported."
                    )
                    : String(
                        localized: "chat.save.subtitle",
                        defaultValue: "\(viewModel.itemName), received in Nearby Chat. Review it before it is imported."
                    )
            )
            content
            Spacer(minLength: 0)
            footer
        }
        .fxSheetContent()
        .frame(width: Theme.Layout.shareSheetWidth)
        .frame(minHeight: Theme.Layout.shareSheetMinHeight)
        .task { await viewModel.prepare() }
        .onDisappear { viewModel.finish() }
        .errorAlert($viewModel.alert)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .choosingTarget:
            ChatImportTargetList(viewModel: viewModel)
        case .choosingFolderDestination:
            if let destination = viewModel.destination {
                FolderDestinationView(model: destination)
            }
        case .folderSaved:
            if let notice = viewModel.folderNotice {
                SheetCallout(systemImage: "checkmark.circle", tint: Theme.Colors.success, text: notice)
            }
        case .preparing:
            NearbyProgressRow(text: String(localized: "chat.save.preparing", defaultValue: "Preparing the preview…"))
        case .preview, .applying:
            if let editor = viewModel.editor {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    if let reason = editor.blockReason {
                        Banner(.danger, message: reason.localizedMessage)
                        if viewModel.needsRepositoryImport {
                            ShareImportRepositoryButton(
                                title: String(
                                    localized: "chat.save.importRepo",
                                    defaultValue: "Import \(viewModel.repositoryFullName ?? "") from GitHub"
                                ),
                                isImporting: viewModel.isImportingRepository,
                                isOnline: viewModel.isOnline
                            ) {
                                Task { await viewModel.importRepository() }
                            }
                        }
                    }
                    ShareImportPreviewView(editor: editor)
                }
            }
        case .done:
            if let result = viewModel.result {
                ShareImportResultView(result: result)
            }
        case .failed:
            if let failure = viewModel.failure {
                InlineErrorView(error: failure)
            } else {
                SheetCallout(
                    systemImage: "xmark.circle",
                    tint: Theme.Colors.subtleText,
                    text: String(localized: "chat.save.wiped", defaultValue: "Nothing was imported. The value was wiped.")
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Spacer()
            switch viewModel.step {
            case .done, .failed, .folderSaved:
                Button(String(localized: "common.done", defaultValue: "Done")) {
                    viewModel.finish()
                }
                .fxButtonStyle(.primary, size: .large)
                .keyboardShortcut(.defaultAction)
            case .choosingFolderDestination:
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    viewModel.finish()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
                Button(viewModel.destination?.choice == .repository ? FolderDestinationCopy.continueTitle : FolderDestinationCopy.saveTitle) {
                    Task { await viewModel.continueFolder() }
                }
                .fxButtonStyle(.primary, size: .large)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canContinueFolder)
            case .choosingTarget:
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    viewModel.finish()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "chat.save.repository.continue", defaultValue: "Continue")) {
                    Task { await viewModel.importIntoSelectedTarget() }
                }
                .fxButtonStyle(.primary, size: .large)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canChooseTarget)
            case .preparing, .preview, .applying:
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                    viewModel.finish()
                }
                .fxButtonStyle(.secondary, size: .large)
                .keyboardShortcut(.cancelAction)
                .disabled(viewModel.step == .applying)
                Button(String(localized: "shareImport.apply", defaultValue: "Import")) {
                    Task { await viewModel.apply() }
                }
                .fxButtonStyle(.primary, size: .large)
                .disabled(!viewModel.canApply)
            }
        }
    }
}

/// The repositories of this vault a received configuration can go to (v0.4.0); those this
/// account may not change are listed with the reason and cannot be chosen.
private struct ChatImportTargetList: View {
    let viewModel: ChatSaveViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SectionLabel(String(localized: "chat.save.repository.target", defaultValue: "Import into"))
            if viewModel.targets.isEmpty {
                Text(String(
                    localized: "chat.save.repository.noTargets",
                    defaultValue: "Your vault has no repository yet. Import one from the sidebar, then try again."
                ))
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.mutedText)
            } else {
                List(selection: $viewModel.selectedTargetID) {
                    ForEach(viewModel.targets) { target in
                        HStack(spacing: Theme.Spacing.small) {
                            Image(systemName: "book.closed")
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Colors.onSelectionSecondary)
                                .accessibilityHidden(true)
                            Text(verbatim: target.fullName)
                                .fxTextStyle(.monoName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let reason = target.readOnlyReason {
                                Text(RepoCapabilityModel.readOnly(reason).chipTitle)
                                    .fxTextStyle(.caption)
                                    .foregroundStyle(Theme.Colors.onSelectionSecondary)
                                    .help(reason.localizedExplanation)
                            } else if target.isSenderRepository {
                                Text(String(localized: "chat.save.repository.sender", defaultValue: "Same as the sender's"))
                                    .fxTextStyle(.caption)
                                    .foregroundStyle(Theme.Colors.onSelectionSecondary)
                            }
                        }
                        .frame(minHeight: Theme.Layout.scopeRowHeight)
                        .tag(target.id)
                        .selectionDisabled(!target.isEditable)
                    }
                }
                .shareListContainer()
                .frame(height: Theme.Layout.chatPickerListHeight)
            }
            SheetCallout(
                systemImage: "info.circle",
                tint: Theme.Colors.subtleText,
                text: String(
                    localized: "chat.save.repository.note",
                    defaultValue: "Environments it does not have are created there. Everything becomes changes for your next Sync; nothing reaches GitHub before you review it there."
                )
            )
        }
    }
}
