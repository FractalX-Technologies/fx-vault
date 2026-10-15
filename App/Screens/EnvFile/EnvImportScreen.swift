import EnvTools
import SwiftUI
import VaultCore
import VaultData

/// EnvImportScreen: file or paste → Key (fixes), Kind (tab default or pre-marked), Conflict,
/// Target scope. Paste mode shows the editor above a preview that updates as you type.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet`. The init signature is fixed; the feature owns everything else in this folder.
/// Dismiss with `@Environment(\.dismiss)`.
struct EnvImportScreen: View {
    @State private var viewModel: EnvImportViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: EnvImportContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: EnvImportViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: Theme.Spacing.largePlus) {
            SheetHeader(
                label: ShareSheetLabel.environmentFile,
                title: String(localized: "envImport.title", defaultValue: "Import .env"),
                subtitle: subtitle
            )
            content
            footer
        }
        .fxSheetContent()
        .frame(width: Theme.Layout.envImportSheetWidth, height: sheetHeight, alignment: .topLeading)
        .screenCaptureProtected()
        .errorAlert($viewModel.alert)
        .onDisappear { viewModel.discard() }
    }

    private var sheetHeight: CGFloat {
        viewModel.step == .paste ? Theme.Layout.envImportPasteSheetHeight : Theme.Layout.envImportSheetHeight
    }

    private var subtitle: String {
        switch viewModel.step {
        case .source:
            String(
                localized: "envImport.subtitle.source",
                defaultValue: "Choose a .env file or paste its contents. Nothing is saved until you review and import."
            )
        case .paste:
            String(
                localized: "envImport.subtitle.paste",
                defaultValue: "Paste or type KEY=value lines. The preview updates as you type; nothing is saved until you import."
            )
        case .review:
            if let fileName = viewModel.sourceFileName {
                String(
                    localized: "envImport.subtitle.reviewFile",
                    defaultValue: "\(viewModel.rows.count) entries in \(fileName). Check names and kinds, then import."
                )
            } else {
                String(
                    localized: "envImport.subtitle.reviewPaste",
                    defaultValue: "\(viewModel.rows.count) entries in the pasted text. Check names and kinds, then import."
                )
            }
        case .done:
            String(localized: "envImport.subtitle.done", defaultValue: "The import is saved in the vault.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .source, .paste:
            EnvImportSourceView(viewModel: viewModel)
        case .review:
            EnvImportReviewView(viewModel: viewModel)
        case .done(let result):
            EnvImportResultView(viewModel: viewModel, result: result)
        }
    }

    /// Status on the left, then Cancel (secondary) and the step's primary pill (mockup SyncReview).
    private var footer: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            switch viewModel.step {
            case .source:
                Spacer()
                progress
                cancelButton
                Button(String(localized: "envImport.chooseFile", defaultValue: "Choose File…"), action: chooseFile)
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.isWorking)
            case .paste:
                Spacer()
                progress
                cancelButton
                importButton
            case .review:
                Button(String(localized: "envImport.startOver", defaultValue: "Start Over")) {
                    viewModel.startOver()
                }
                .fxButtonStyle(.outline, size: .large)
                Spacer()
                progress
                cancelButton
                importButton
            case .done:
                Spacer()
                Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var cancelButton: some View {
        Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
            .fxButtonStyle(.secondary, size: .large)
            .keyboardShortcut(.cancelAction)
    }

    private var importButton: some View {
        Button(String(localized: "envImport.import", defaultValue: "Import \(viewModel.includedRows.count)")) {
            viewModel.importRows()
        }
        .fxButtonStyle(.primary, size: .large)
        .keyboardShortcut(.defaultAction)
        .disabled(!viewModel.canImport)
    }

    @ViewBuilder
    private var progress: some View {
        if viewModel.isWorking || viewModel.isParsePending {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func chooseFile() {
        guard let url = EnvFilePanels.chooseImportFile() else { return }
        Task { await viewModel.loadFile(at: url) }
    }
}

/// Source and paste steps: File / Paste picker, then the file button's explanation, or the
/// secure paste editor above the live preview.
private struct EnvImportSourceView: View {
    @Bindable var viewModel: EnvImportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SegmentedPill(
                selection: $viewModel.sourceKind,
                segments: [
                    .init(value: EnvImportSourceKind.file, title: String(localized: "envImport.source.file", defaultValue: "File")),
                    .init(value: EnvImportSourceKind.paste, title: String(localized: "envImport.source.paste", defaultValue: "Paste")),
                ],
                accessibilityLabel: String(localized: "envImport.source", defaultValue: "Source")
            )
            .fixedSize()

            switch viewModel.sourceKind {
            case .file:
                SheetCallout(
                    systemImage: "doc.text",
                    tint: Theme.Colors.subtleText,
                    text: String(
                        localized: "envImport.source.fileHint",
                        defaultValue: "Hidden files such as .env are shown in the file picker. The file is read once and never changed."
                    )
                )
                Spacer(minLength: 0)
            case .paste:
                EnvPasteEditorSection(viewModel: viewModel)
                EnvImportPreviewSection(viewModel: viewModel)
            }
        }
    }
}

/// The secure paste editor with Paste (clipboard, user action) and Clear.
private struct EnvPasteEditorSection: View {
    @Bindable var viewModel: EnvImportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            EnvPasteEditorView(text: $viewModel.pastedText, focusesOnAppear: viewModel.focusesPasteEditor)
                .frame(height: Theme.Layout.envPasteEditorHeight)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: Theme.Stroke.hairline)
                )
                .accessibilityLabel(String(localized: "envImport.paste.accessibilityLabel", defaultValue: ".env contents"))
            HStack(spacing: Theme.Spacing.small) {
                Text(String(
                    localized: "envImport.paste.liveHint",
                    defaultValue: "KEY=value lines, as in a .env file. The text is cleared when you import or close this sheet."
                ))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                Spacer()
                // A user-initiated clipboard read: FX Vault never reads the pasteboard by itself.
                PasteButton(payloadType: String.self) { @Sendable strings in
                    Task { @MainActor in
                        viewModel.pasteFromClipboard(strings)
                    }
                }
                .controlSize(.small)
                Button(String(localized: "envImport.paste.clear", defaultValue: "Clear")) {
                    viewModel.clearPastedText()
                }
                .fxButtonStyle(.ghost)
                .disabled(viewModel.isPastedTextEmpty)
            }
            if let problem = viewModel.pasteProblem {
                Label {
                    Text(verbatim: "\(problem.title) \(problem.message)")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(Theme.Colors.danger)
                }
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.ink)
            }
        }
    }
}

/// The live preview under the paste editor: the same controls and table as the file review,
/// with an empty state while nothing parses.
private struct EnvImportPreviewSection: View {
    let viewModel: EnvImportViewModel

    var body: some View {
        if viewModel.rows.isEmpty && viewModel.issues.isEmpty {
            EmptyStateView(
                systemImage: viewModel.isPastedTextEmpty ? "doc.on.clipboard" : "doc.text.magnifyingglass",
                title: viewModel.isPastedTextEmpty
                    ? String(localized: "envImport.paste.empty.title", defaultValue: "Paste your .env")
                    : String(localized: "envImport.empty.title", defaultValue: "No entries"),
                message: viewModel.isPastedTextEmpty
                    ? String(
                        localized: "envImport.paste.empty.message",
                        defaultValue: "Paste or type KEY=value lines above. Each line becomes a row here."
                    )
                    : String(
                        localized: "envImport.paste.noEntries.message",
                        defaultValue: "No KEY=value lines were found in the text above."
                    )
            ) {
                EmptyView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EnvImportReviewView(viewModel: viewModel)
        }
    }
}

/// Review step and live preview: target scope, bulk actions, the table and the parse issues.
private struct EnvImportReviewView: View {
    let viewModel: EnvImportViewModel

    var body: some View {
        let targetTitle = String(localized: "envImport.target", defaultValue: "Import into")
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .center, spacing: Theme.Spacing.medium) {
                SectionLabel(targetTitle)
                Picker(
                    targetTitle,
                    selection: Binding(get: { viewModel.targetScope }, set: { viewModel.selectTarget($0) })
                ) {
                    ForEach(viewModel.scopeOptions) { option in
                        Text(verbatim: option.title)
                            .tag(option.scope)
                            .disabled(!option.isEditable)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                if viewModel.canOverwriteAll {
                    Button(String(localized: "envImport.overwriteAll", defaultValue: "Overwrite All")) {
                        viewModel.overwriteAllConflicts()
                    }
                    .fxButtonStyle(.outline)
                    .help(String(
                        localized: "envImport.overwriteAll.help",
                        defaultValue: "Replace the existing value of every name that already exists in this scope."
                    ))
                }
            }
            HStack(spacing: Theme.Spacing.xSmall) {
                Button(String(localized: "envImport.includeAll", defaultValue: "Include All")) {
                    viewModel.setAllIncluded(true)
                }
                Button(String(localized: "envImport.includeNone", defaultValue: "Include None")) {
                    viewModel.setAllIncluded(false)
                }
                Spacer()
                Button(String(localized: "envImport.markAllVariable", defaultValue: "Mark All as Variable")) {
                    viewModel.markAll(as: .variable)
                }
                Button(String(localized: "envImport.markAllSecret", defaultValue: "Mark All as Secret")) {
                    viewModel.markAll(as: .secret)
                }
            }
            .fxButtonStyle(.ghost)
            if let problem = viewModel.targetProblem {
                Banner(.warning, message: problem, systemImage: "lock")
            }
            EnvImportTableView(viewModel: viewModel)
            if !viewModel.issues.isEmpty {
                EnvImportIssueList(issues: viewModel.issues)
            }
        }
    }
}

/// The parse issues with their line numbers (errors skipped the line, warnings kept it).
private struct EnvImportIssueList: View {
    let issues: [EnvParseIssueRowModel]

    init(issues: [EnvParseIssue]) {
        self.issues = issues.enumerated().map { EnvParseIssueRowModel(index: $0.offset, issue: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(String(localized: "envImport.issues.title", defaultValue: "Lines to check"))
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    ForEach(issues) { row in
                        Label {
                            Text(verbatim: "\(row.issue.localizedLocation): \(row.issue.localizedMessage)")
                                .fxTextStyle(.caption)
                                .foregroundStyle(Theme.Colors.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: row.issue.severity == .error ? "xmark.circle" : "exclamationmark.triangle")
                                .foregroundStyle(row.issue.severity == .error ? Theme.Colors.danger : Theme.Colors.warning)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Theme.Layout.envIssueListMaxHeight)
        }
    }
}

/// One parse issue in a list (issues have no identity of their own).
private struct EnvParseIssueRowModel: Identifiable {
    let index: Int
    let issue: EnvParseIssue

    var id: Int {
        index
    }
}

/// Done step: added, replaced and skipped names, and the Sync reminder.
private struct EnvImportResultView: View {
    let viewModel: EnvImportViewModel
    let result: EnvImportResultModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    ForEach(Array(viewModel.summaryLines(for: result).enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                            .fxTextStyle(.body)
                            .foregroundStyle(Theme.Colors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if viewModel.hasPendingChanges(result) {
                Banner(.info, message: String(
                    localized: "envImport.result.syncHint",
                    defaultValue: "These are local changes. Use Sync to push them to GitHub."
                ))
            }
        }
    }
}
