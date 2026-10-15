import SharingKit
import SwiftUI
import VaultCore
import VaultData

/// Import a `.fxvault` share (§10 `ShareImportScreen`): passphrase → preview and merge choices →
/// apply. See ``ShareImportViewModel`` for the rules.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.shareImport` (from the Share menu or a `.fxvault` file opened in Finder/AirDrop).
struct ShareImportScreen: View {
    @State private var viewModel: ShareImportViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isPassphraseFocused: Bool

    init(context: ShareImportContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: ShareImportViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(
                label: ShareSheetLabel.share,
                title: String(localized: "shareImport.title", defaultValue: "Import Share"),
                subtitle: viewModel.fileName
            )
            content
            Spacer(minLength: 0)
            footer
        }
        .fxSheetContent()
        .frame(width: Theme.Layout.shareSheetWidth)
        .frame(minHeight: Theme.Layout.shareSheetMinHeight)
        .task { await viewModel.start() }
        .onDisappear { viewModel.close() }
        .errorAlert($viewModel.alert)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .reading:
            NearbyProgressRow(text: String(localized: "shareImport.reading", defaultValue: "Reading the file…"))
        case .passphrase, .opening:
            passphraseStep
        case .preview, .applying:
            previewStep
        case .done:
            if let result = viewModel.result {
                ShareImportResultView(result: result)
            }
        case .failed:
            if let failure = viewModel.failure {
                InlineErrorView(error: failure)
            }
        }
    }

    private var passphraseStep: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(String(
                localized: "shareImport.passphrase.prompt",
                defaultValue: "Enter the six-word passphrase the sender gave you."
            ))
            .fxTextStyle(.body)
            .foregroundStyle(Theme.Colors.mutedText)
            SecureField(
                String(localized: "shareImport.passphrase.placeholder", defaultValue: "word-word-word-word-word-word"),
                text: $viewModel.passphrase
            )
            .focused($isPassphraseFocused)
            .fxInputField(
                .rounded,
                isFocused: isPassphraseFocused,
                isInvalid: viewModel.passphraseError != nil,
                isMonospaced: true
            )
            .disabled(viewModel.step == .opening)
            .onSubmit(open)
            .onAppear { isPassphraseFocused = true }
            HStack(spacing: Theme.Spacing.small) {
                Text(String(
                    localized: "shareImport.passphrase.count",
                    defaultValue: "\(viewModel.typedWordCount) of \(Limits.passphraseWordCount) words"
                ))
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.subtleText)
                if viewModel.step == .opening {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "shareImport.opening", defaultValue: "Decrypting…"))
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                }
            }
            if let error = viewModel.passphraseError {
                InlineErrorView(error: error)
            }
        }
    }

    @ViewBuilder
    private var previewStep: some View {
        if let editor = viewModel.editor {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                if let reason = editor.blockReason {
                    blockedBanner(reason)
                }
                ShareImportPreviewView(editor: editor)
            }
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

    private var footer: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Spacer()
            switch viewModel.step {
            case .done, .failed:
                Button(String(localized: "common.done", defaultValue: "Done")) {
                    dismiss()
                }
                .fxButtonStyle(.primary, size: .large)
                .keyboardShortcut(.defaultAction)
            case .reading, .passphrase, .opening:
                cancelButton
                Button(String(localized: "shareImport.open", defaultValue: "Open"), action: open)
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canOpen)
            case .preview, .applying:
                cancelButton
                Button(String(localized: "shareImport.apply", defaultValue: "Import")) {
                    Task { await viewModel.apply() }
                }
                .fxButtonStyle(.primary, size: .large)
                .disabled(!viewModel.canApply)
            }
        }
    }

    private var cancelButton: some View {
        Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
            dismiss()
        }
        .fxButtonStyle(.secondary, size: .large)
        .keyboardShortcut(.cancelAction)
    }

    private func open() {
        Task { await viewModel.open() }
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
