import SwiftUI
import VaultCore
import VaultData

/// The import table (§10 `EnvImportScreen`): Include, Line, Key (editable, with the KeyNormalizer
/// fix and notes), Kind (pre-marked, editable) and Conflict (Skip/Overwrite when the name exists
/// in the target scope). Shows names only, never values.
struct EnvImportTableView: View {
    let viewModel: EnvImportViewModel

    var body: some View {
        Table(viewModel.rows) {
            TableColumn(String(localized: "envImport.column.include", defaultValue: "Import")) { row in
                Toggle(
                    String(localized: "envImport.column.include.toggle", defaultValue: "Import \(row.originalKey)"),
                    isOn: Binding(get: { row.isIncluded }, set: { viewModel.setIncluded($0, forRow: row.id) })
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!row.canInclude)
            }
            .width(Theme.Layout.envImportIncludeColumnWidth)
            TableColumn(String(localized: "envImport.column.line", defaultValue: "Line")) { row in
                Text(verbatim: "\(row.line)")
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .width(Theme.Layout.envImportLineColumnWidth)
            TableColumn(String(localized: "envImport.column.key", defaultValue: "Key")) { row in
                EnvImportKeyCell(viewModel: viewModel, row: row)
            }
            .width(min: Theme.Layout.envImportKeyColumnMinWidth)
            TableColumn(String(localized: "envImport.column.kind", defaultValue: "Kind")) { row in
                EnvImportKindCell(viewModel: viewModel, row: row)
            }
            .width(Theme.Layout.envImportKindColumnWidth)
            TableColumn(String(localized: "envImport.column.conflict", defaultValue: "Conflict")) { row in
                EnvImportConflictCell(viewModel: viewModel, row: row)
            }
            .width(Theme.Layout.envImportConflictColumnWidth)
        }
        .overlay {
            if viewModel.rows.isEmpty {
                EmptyStateView(
                    systemImage: "doc.text.magnifyingglass",
                    title: String(localized: "envImport.empty.title", defaultValue: "No entries"),
                    message: viewModel.step == .paste
                        ? String(
                            localized: "envImport.empty.pasteMessage",
                            defaultValue: "No KEY=value lines were found. Check the lines listed below, or edit the text above."
                        )
                        : String(
                            localized: "envImport.empty.message",
                            defaultValue: "No KEY=value lines were found. Check the lines listed below, or start over."
                        )
                )
            }
        }
    }
}

/// The editable GitHub name with the original key, fixes and problems underneath.
private struct EnvImportKeyCell: View {
    let viewModel: EnvImportViewModel
    let row: EnvImportRowModel

    var body: some View {
        let problem = row.isIncluded ? viewModel.nameProblem(for: row) : nil
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            HStack(spacing: Theme.Spacing.xSmall) {
                TextField(
                    String(localized: "envImport.column.key.placeholder", defaultValue: "NAME"),
                    text: Binding(get: { row.name }, set: { viewModel.setName($0, forRow: row.id) })
                )
                .font(Theme.Typography.monospaced)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .disabled(!row.canInclude)
                if row.differsFromSuggestion {
                    Button {
                        viewModel.useSuggestedName(forRow: row.id)
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "envImport.key.useSuggestion", defaultValue: "Use the suggested name"))
                }
            }
            ForEach(viewModel.keyNotes(for: row), id: \.self) { note in
                Text(verbatim: note)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(2)
            }
            if let problem {
                Text(verbatim: problem)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.danger)
                    .lineLimit(2)
            }
        }
        .opacity(row.isIncluded ? 1 : Theme.Opacity.disabled)
    }
}

/// Secret / Variable, with the credential mark, and the "credential as variable" warning badge
/// whose click makes the row a secret.
private struct EnvImportKindCell: View {
    let viewModel: EnvImportViewModel
    let row: EnvImportRowModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            HStack(spacing: Theme.Spacing.xSmall) {
                Picker(
                    String(localized: "envImport.column.kind", defaultValue: "Kind"),
                    selection: Binding(get: { row.kind }, set: { viewModel.setKind($0, forRow: row.id) })
                ) {
                    ForEach([ConfigKind.secret, ConfigKind.variable], id: \.self) { kind in
                        Text(verbatim: kind.envImportTitle).tag(kind)
                    }
                }
                .labelsHidden()
                .disabled(!row.canInclude)
                if viewModel.kindWarning(for: row) == nil, let hint = viewModel.credentialHint(for: row) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .help(hint)
                        .accessibilityLabel(hint)
                }
            }
            if let warning = viewModel.kindWarning(for: row) {
                Button {
                    viewModel.makeSecret(forRow: row.id)
                } label: {
                    Label(
                        String(localized: "envImport.kind.makeSecret", defaultValue: "Make Secret"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.warning)
                }
                .buttonStyle(.borderless)
                .disabled(!row.canInclude)
                .help(warning)
                .accessibilityHint(warning)
            }
        }
    }
}

/// "New", or the Skip / Overwrite choice when the name exists in the target scope.
private struct EnvImportConflictCell: View {
    let viewModel: EnvImportViewModel
    let row: EnvImportRowModel

    var body: some View {
        if viewModel.hasConflict(row) {
            Picker(
                String(localized: "envImport.column.conflict", defaultValue: "Conflict"),
                selection: Binding(get: { row.onConflict }, set: { viewModel.setConflictChoice($0, forRow: row.id) })
            ) {
                ForEach(EnvImportConflictChoice.allCases, id: \.self) { choice in
                    Text(verbatim: choice.localizedTitle).tag(choice)
                }
            }
            .labelsHidden()
            .help(String(
                localized: "envImport.conflict.help",
                defaultValue: "This name already exists in the scope. Skip keeps the existing value; Overwrite replaces it."
            ))
        } else {
            Text(String(localized: "envImport.conflict.none", defaultValue: "New"))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }
}
