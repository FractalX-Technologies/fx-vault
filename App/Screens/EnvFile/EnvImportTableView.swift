import SwiftUI
import VaultCore
import VaultData

/// The import table (§10 `EnvImportScreen`): Include, Line, Key (editable, with the KeyNormalizer
/// fix and notes), Kind (pre-marked, editable) and Conflict (Skip/Overwrite when the name exists
/// in the target scope). Shows names only, never values. Styled like the main table
/// (docs/DESIGN.md, "Tables and rows"): mono names, 52 pt rows, chips.
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
                .fxTableCell()
            }
            .width(Theme.Layout.envImportIncludeColumnWidth)
            TableColumn(String(localized: "envImport.column.line", defaultValue: "Line")) { row in
                TableMetaText(String(row.line))
                    .fxTableCell()
            }
            .width(Theme.Layout.envImportLineColumnWidth)
            TableColumn(String(localized: "envImport.column.key", defaultValue: "Key")) { row in
                EnvImportKeyCell(viewModel: viewModel, row: row)
                    .fxTableCell()
            }
            .width(min: Theme.Layout.envImportKeyColumnMinWidth)
            TableColumn(String(localized: "envImport.column.kind", defaultValue: "Kind")) { row in
                EnvImportKindCell(viewModel: viewModel, row: row)
                    .fxTableCell()
            }
            .width(Theme.Layout.envImportKindColumnWidth)
            TableColumn(String(localized: "envImport.column.conflict", defaultValue: "Conflict")) { row in
                EnvImportConflictCell(viewModel: viewModel, row: row)
                    .fxTableCell()
            }
            .width(Theme.Layout.envImportConflictColumnWidth)
        }
        .fxTable()
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
                .fxTextStyle(.monoName)
                .foregroundStyle(Theme.Colors.ink)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .disabled(!row.canInclude)
                if row.differsFromSuggestion {
                    Button {
                        viewModel.useSuggestedName(forRow: row.id)
                    } label: {
                        Label(
                            String(localized: "envImport.key.useSuggestion", defaultValue: "Use the suggested name"),
                            systemImage: "wand.and.stars"
                        )
                    }
                    .fxIconButtonStyle(.ghost)
                    .help(String(localized: "envImport.key.useSuggestion", defaultValue: "Use the suggested name"))
                }
            }
            ForEach(viewModel.keyNotes(for: row), id: \.self) { note in
                Text(verbatim: note)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .lineLimit(2)
            }
            if let problem {
                Text(verbatim: problem)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.danger)
                    .lineLimit(2)
            }
        }
        .opacity(row.isIncluded ? 1 : Theme.Opacity.disabled)
    }
}

/// Secret / Variable as a chip that toggles the kind (filled = secret, outlined = variable),
/// with the credential mark, and the "credential as variable" warning chip whose click makes the
/// row a secret.
private struct EnvImportKindCell: View {
    let viewModel: EnvImportViewModel
    let row: EnvImportRowModel

    private var otherKind: ConfigKind {
        row.kind == .secret ? .variable : .secret
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack(spacing: Theme.Spacing.xSmall) {
                Button {
                    viewModel.setKind(otherKind, forRow: row.id)
                } label: {
                    StatusChip(
                        title: row.kind.envImportTitle,
                        tone: .neutral,
                        fill: row.kind == .secret ? .filled : .outlined,
                        showsDot: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(!row.canInclude)
                .help(String(
                    localized: "envImport.kind.toggle.help",
                    defaultValue: "Click to import it as a \(otherKind.envImportTitle)."
                ))
                .accessibilityLabel(String(localized: "envImport.column.kind", defaultValue: "Kind"))
                .accessibilityValue(row.kind.envImportTitle)
                .accessibilityHint(String(
                    localized: "envImport.kind.toggle.help",
                    defaultValue: "Click to import it as a \(otherKind.envImportTitle)."
                ))
                if viewModel.kindWarning(for: row) == nil, let hint = viewModel.credentialHint(for: row) {
                    Image(systemName: "key.fill")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .help(hint)
                        .accessibilityLabel(hint)
                }
            }
            if let warning = viewModel.kindWarning(for: row) {
                Button {
                    viewModel.makeSecret(forRow: row.id)
                } label: {
                    StatusChip(
                        title: String(localized: "envImport.kind.makeSecret", defaultValue: "Make Secret"),
                        tone: .warning
                    )
                }
                .buttonStyle(.plain)
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
            .fixedSize()
            .help(String(
                localized: "envImport.conflict.help",
                defaultValue: "This name already exists in the scope. Skip keeps the existing value; Overwrite replaces it."
            ))
        } else {
            StatusChip(title: String(localized: "envImport.conflict.none", defaultValue: "New"), tone: .brand)
        }
    }
}
