import SharingKit
import SwiftUI
import VaultCore
import VaultData

/// Open a `.fxvault` file (§10 `ShareImportScreen`; boards Share-Open, Share-OpenPreview,
/// Share-Expired): passphrase → preview and merge choices → apply (``ShareImportViewModel``).
/// UI feature contract entry view (ARCHITECTURE.md): `MainScreen` presents it for
/// `MainSheet.shareImport` (the Share menu, or a `.fxvault` file opened in Finder or AirDrop).
struct ShareImportScreen: View {
    @State private var viewModel: ShareImportViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isPassphraseFocused: Bool

    init(context: ShareImportContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: ShareImportViewModel(context: context, dependencies: dependencies))
    }

    /// Shows an existing view model (previews and the visual snapshot tests).
    init(viewModel: ShareImportViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        Group {
            if viewModel.step == .failed, let failure = viewModel.failure {
                ShareRefusedView(failure: failure, hasExpired: viewModel.hasExpired, fileName: viewModel.fileName) {
                    dismiss()
                }
            } else {
                DialogSheet(
                    title: ProjectShareCopy.openTitle(viewModel.fileName),
                    subtitle: subtitle,
                    footerNote: footerNote,
                    isWorking: viewModel.step == .bundleApplying || viewModel.step == .applying
                ) {
                    content
                } actions: {
                    actions
                }
            }
        }
        .frame(width: width)
        .frame(maxHeight: Theme.Layout.shareSheetMaxHeight)
        .task { await viewModel.start() }
        .onDisappear { viewModel.close() }
        .errorAlert($viewModel.alert)
    }

    private var width: CGFloat {
        switch viewModel.step {
        case .reading, .passphrase, .opening: Theme.Layout.shareOpenWidth
        case .bundlePreview, .bundleApplying: Theme.Layout.shareOpenPreviewWidth
        case .failed: Theme.Layout.shareExpiredWidth
        case .preview, .applying, .done, .folderDestination, .folderSaved, .bundleDone: Theme.Layout.shareSheetWidth
        }
    }

    /// When the file was made and when FX Vault stops opening it (board Share-OpenPreview).
    private var subtitle: String? {
        guard let editor = viewModel.bundleEditor, viewModel.step == .bundlePreview || viewModel.step == .bundleApplying else {
            return nil
        }
        return ProjectShareCopy.unlocked(created: editor.createdAt, expires: editor.expiresAt)
    }

    private var footerNote: String? {
        switch viewModel.step {
        case .bundlePreview:
            ProjectShareCopy.nothingSyncs
        case .bundleApplying:
            viewModel.bundleEditor?.needsRepositoryImport == true && viewModel.isOnline
                ? ProjectShareCopy.importing
                : String(localized: "shareImport.applying", defaultValue: "Importing…")
        default:
            nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .reading:
            SheetProgressRow(text: String(localized: "shareImport.reading", defaultValue: "Reading the file…"))
        case .passphrase, .opening:
            passphraseStep
        case .preview, .applying:
            previewStep
        case .done:
            if let result = viewModel.result {
                ShareImportResultView(result: result)
            }
        case .folderDestination:
            if let destination = viewModel.destination {
                if viewModel.wasFolderImported {
                    Banner(.warning, message: FolderShareCopy.alreadyImported)
                }
                FolderDestinationView(model: destination)
            }
        case .folderSaved:
            if let notice = viewModel.folderNotice {
                SheetCallout(systemImage: "checkmark.circle", tint: Theme.Colors.success, text: notice)
            }
        case .bundlePreview, .bundleApplying:
            if let editor = viewModel.bundleEditor {
                ProjectShareImportView(editor: editor, isOnline: viewModel.isOnline)
                    .disabled(viewModel.step == .bundleApplying)
            }
        case .bundleDone:
            if let result = viewModel.bundleResult {
                ProjectShareImportResultView(result: result, failedRepositories: viewModel.failedRepositories)
            }
        case .failed:
            EmptyView()
        }
    }

    /// The six words in one mono field (board Share-Open), with the count and the error as notes.
    private var passphraseStep: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            Text(ProjectShareCopy.passphraseLabel)
                .fxTextStyle(.formLabel)
                .foregroundStyle(Theme.Colors.mutedText)
                .accessibilityHidden(true)
            SecureField(text: $viewModel.passphrase, prompt: Text(ProjectShareCopy.passphrasePrompt)) {
                Text(ProjectShareCopy.passphraseLabel)
            }
            .focused($isPassphraseFocused)
            .fxInputField(
                .dialog,
                isFocused: isPassphraseFocused,
                isInvalid: viewModel.passphraseError != nil,
                isMonospaced: true
            )
            .disabled(viewModel.step == .opening)
            .onSubmit(open)
            .onAppear { isPassphraseFocused = true }
            HStack(spacing: Theme.Spacing.small) {
                ConfigEditorNoteView(
                    note: .info(String(
                        localized: "shareImport.passphrase.count",
                        defaultValue: "\(viewModel.typedWordCount) of \(Limits.passphraseWordCount) words"
                    )),
                    style: .dialog
                )
                if viewModel.step == .opening {
                    ProgressView()
                        .controlSize(.mini)
                    ConfigEditorNoteView(
                        note: .info(String(localized: "shareImport.opening", defaultValue: "Decrypting…")),
                        style: .dialog
                    )
                }
            }
            if let error = viewModel.passphraseError {
                ConfigEditorNoteView(note: .error(error.title), style: .dialog)
                ConfigEditorNoteView(note: .info(error.message), style: .dialog)
            }
        }
    }

    @ViewBuilder
    private var previewStep: some View {
        if let editor = viewModel.editor {
            if let reason = editor.blockReason {
                blockedBanner(reason)
            }
            ShareImportPreviewView(editor: editor)
        }
    }

    private func blockedBanner(_ reason: ShareImportBlockReason) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Banner(.danger, message: reason.localizedMessage)
            if viewModel.needsRepositoryImport {
                ShareImportRepositoryButton(
                    title: String(
                        localized: "shareImport.importRepo",
                        defaultValue: "Import \(viewModel.repositoryFullName ?? "") from GitHub"
                    ),
                    isImporting: viewModel.isImportingRepository,
                    isOnline: viewModel.isOnline
                ) {
                    Task { await viewModel.importRepository() }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch viewModel.step {
        case .done, .failed, .folderSaved, .bundleDone:
            Button(String(localized: "common.done", defaultValue: "Done")) {
                dismiss()
            }
            .fxButtonStyle(.primary, size: .dialog)
            .keyboardShortcut(.defaultAction)
        case .reading, .passphrase, .opening:
            cancelButton
            Button(String(localized: "shareImport.open", defaultValue: "Open"), action: open)
                .fxButtonStyle(.primary, size: .dialog)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canOpen)
        case .preview, .applying:
            cancelButton
            Button(String(localized: "shareImport.apply", defaultValue: "Import")) {
                Task { await viewModel.apply() }
            }
            .fxButtonStyle(.primary, size: .dialog)
            .disabled(!viewModel.canApply)
        case .bundlePreview, .bundleApplying:
            cancelButton
            Button(ProjectShareCopy.importAsHeld) {
                Task { await viewModel.applyBundle() }
            }
            .fxButtonStyle(.primary, size: .dialog)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canApplyBundle)
        case .folderDestination:
            cancelButton
            Button(viewModel.destination?.choice == .repository ? FolderDestinationCopy.continueTitle : FolderDestinationCopy.saveTitle) {
                Task { await viewModel.continueFolder() }
            }
            .fxButtonStyle(.primary, size: .dialog)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.canContinueFolder)
        }
    }

    private var cancelButton: some View {
        Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
            dismiss()
        }
        .fxButtonStyle(.outline, size: .dialog)
        .keyboardShortcut(.cancelAction)
    }

    private func open() {
        Task { await viewModel.open() }
    }
}

/// A file that cannot be opened here (board Share-Expired): the symbol, why, the file's name and
/// OK, centred.
private struct ShareRefusedView: View {
    let failure: ErrorPresentationModel
    let hasExpired: Bool
    let fileName: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumPlus) {
            VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
                Image(systemName: hasExpired ? "clock.badge.xmark" : "exclamationmark.triangle")
                    .font(Theme.Typography.dialogSymbol)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .accessibilityHidden(true)
                SheetHeader.dialog(failure.title, subtitle: failure.message)
                Text(verbatim: fileName)
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button(String(localized: "common.ok", defaultValue: "OK"), action: onDismiss)
                .fxButtonStyle(.primary, size: .dialog)
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity)
        }
        .padding(Theme.Layout.dialogInset)
        .fxSheetBackground()
    }
}

/// What an import changed (names only), with the "from share, unverified" note (§9.5).
struct ShareImportResultView: View {
    let result: ShareImportResultModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ShareNoteView(
                systemImage: "checkmark.circle",
                text: String(localized: "shareImport.done.title", defaultValue: "Imported into your vault"),
                tint: Theme.Colors.success
            )
            Card(.container, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    if index > 0 {
                        HairlineDivider()
                    }
                    Text(line)
                        .fxTextStyle(.callout)
                        .foregroundStyle(Theme.Colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Spacing.medium)
                        .padding(.horizontal, Theme.Spacing.large)
                }
            }
            SheetCallout(
                systemImage: "questionmark.diamond",
                tint: Theme.Colors.warning,
                text: String(
                    localized: "shareImport.done.unverified",
                    defaultValue: "Imported values show “Unverified share” until a Sync pushes them or confirms they match GitHub. Nothing was synced."
                )
            )
        }
    }

    private var lines: [String] {
        var lines: [String] = []
        func add(_ count: Int, _ text: String) {
            if count > 0 { lines.append(text) }
        }
        add(result.added.count, String(localized: "shareImport.done.added", defaultValue: "\(result.added.count) added"))
        add(result.filled.count, String(localized: "shareImport.done.filled", defaultValue: "\(result.filled.count) missing values filled"))
        add(
            result.overwritten.count,
            String(localized: "shareImport.done.overwritten", defaultValue: "\(result.overwritten.count) overwritten")
        )
        add(
            result.addedWithoutValue.count,
            String(
                localized: "shareImport.done.withoutValue",
                defaultValue: "\(result.addedWithoutValue.count) added without a value"
            )
        )
        add(
            result.environmentsCreated.count,
            String(
                localized: "shareImport.done.environments",
                defaultValue: "\(result.environmentsCreated.count) environments created"
            )
        )
        add(
            result.policiesChanged.count,
            String(
                localized: "shareImport.done.policies",
                defaultValue: "\(result.policiesChanged.count) deployment branch policies changed"
            )
        )
        add(
            result.skippedVariablesWithoutValue.count,
            String(
                localized: "shareImport.done.skippedVariables",
                defaultValue: "\(result.skippedVariablesWithoutValue.count) variables without a value skipped"
            )
        )
        add(
            result.strippedTrailingNewlines.count,
            String(
                localized: "shareImport.done.newlines",
                defaultValue: "\(result.strippedTrailingNewlines.count) values lost a trailing line break"
            )
        )
        if lines.isEmpty {
            lines.append(String(localized: "shareImport.done.nothing", defaultValue: "Nothing changed."))
        }
        return lines
    }
}
