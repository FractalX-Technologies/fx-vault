import EnvTools
import SwiftUI
import VaultCore
import VaultData

/// EnvImportScreen: file or paste → Key (fixes), Kind (pre-marked), Conflict, Target scope.
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
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            CardHeader(
                systemImage: "square.and.arrow.down",
                title: String(localized: "envImport.title", defaultValue: "Import .env"),
                subtitle: subtitle
            )
            content
            footer
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: Theme.Layout.envImportSheetWidth, height: Theme.Layout.envImportSheetHeight, alignment: .topLeading)
        .screenCaptureProtected()
        .errorAlert($viewModel.alert)
        .onDisappear { viewModel.discard() }
    }

    private var subtitle: String {
        switch viewModel.step {
        case .source:
            String(
                localized: "envImport.subtitle.source",
                defaultValue: "Choose a .env file or paste its contents. Nothing is saved until you review and import."
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
        case .source:
            EnvImportSourceView(viewModel: viewModel)
        case .review:
            EnvImportReviewView(viewModel: viewModel)
        case .done(let result):
            EnvImportResultView(viewModel: viewModel, result: result)
        }
    }

    private var footer: some View {
        HStack {
            switch viewModel.step {
            case .source:
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                progress
                if viewModel.defaultAction == .chooseFile {
                    Button(String(localized: "envImport.chooseFile", defaultValue: "Choose File…"), action: chooseFile)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(viewModel.isWorking)
                } else {
                    Button(String(localized: "envImport.review", defaultValue: "Review")) {
                        viewModel.reviewPastedText()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canReviewPastedText)
                }
            case .review:
                Button(String(localized: "common.cancel", defaultValue: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "envImport.startOver", defaultValue: "Start Over")) {
                    viewModel.startOver()
                }
                Spacer()
                progress
                Button(String(localized: "envImport.import", defaultValue: "Import \(viewModel.includedRows.count)")) {
                    viewModel.importRows()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canImport)
            case .done:
                Spacer()
                Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        if viewModel.isWorking {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func chooseFile() {
        guard let url = EnvFilePanels.chooseImportFile() else { return }
        Task { await viewModel.loadFile(at: url) }
    }
}

/// Source step: File / Paste picker, the file button's explanation or the secure paste editor.
private struct EnvImportSourceView: View {
    @Bindable var viewModel: EnvImportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Picker(String(localized: "envImport.source", defaultValue: "Source"), selection: $viewModel.sourceKind) {
                Text(String(localized: "envImport.source.file", defaultValue: "File")).tag(EnvImportSourceKind.file)
                Text(String(localized: "envImport.source.paste", defaultValue: "Paste")).tag(EnvImportSourceKind.paste)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            switch viewModel.sourceKind {
            case .file:
                Label(
                    String(
                        localized: "envImport.source.fileHint",
                        defaultValue: "Hidden files such as .env are shown in the file picker. The file is read once and never changed."
                    ),
                    systemImage: "doc.text"
                )
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
            case .paste:
                SecretTextViewRepresentable(text: $viewModel.pastedText) { _ in }
                    .frame(height: Theme.Layout.envPasteEditorHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.medium)
                            .strokeBorder(Theme.Colors.textSecondary.opacity(Theme.Opacity.chipBackground))
                    )
                    .accessibilityLabel(String(localized: "envImport.paste.accessibilityLabel", defaultValue: ".env contents"))
                Text(String(
                    localized: "envImport.paste.hint",
                    defaultValue: "KEY=value lines, as in a .env file. The text is cleared as soon as it is parsed."
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Review step: target scope, the table and the parse issues.
private struct EnvImportReviewView: View {
    let viewModel: EnvImportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Picker(
                    String(localized: "envImport.target", defaultValue: "Import into"),
                    selection: Binding(get: { viewModel.targetScope }, set: { viewModel.selectTarget($0) })
                ) {
                    ForEach(viewModel.scopeOptions) { option in
                        Text(verbatim: option.title)
                            .tag(option.scope)
                            .disabled(!option.isEditable)
                    }
                }
                .fixedSize()
                Spacer()
                Button(String(localized: "envImport.includeAll", defaultValue: "Include All")) {
                    viewModel.setAllIncluded(true)
                }
                Button(String(localized: "envImport.includeNone", defaultValue: "Include None")) {
                    viewModel.setAllIncluded(false)
                }
            }
            if let problem = viewModel.targetProblem {
                Label(problem, systemImage: "lock")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.warning)
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
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Text(String(localized: "envImport.issues.title", defaultValue: "Lines to check"))
                .font(Theme.Typography.callout.weight(.semibold))
                .foregroundStyle(Theme.Colors.textPrimary)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    ForEach(issues) { row in
                        Label {
                            Text(verbatim: "\(row.issue.localizedLocation): \(row.issue.localizedMessage)")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textPrimary)
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
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if viewModel.hasPendingChanges(result) {
                Label(
                    String(
                        localized: "envImport.result.syncHint",
                        defaultValue: "These are local changes. Use Sync to push them to GitHub."
                    ),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.pending)
            }
        }
    }
}
