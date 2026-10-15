import SwiftUI
import SyncEngine

/// One drift finding: the alert copy, the scope, and Keep Local / Accept GitHub with what each
/// does. Neither choice is a default button.
struct DriftFindingRow: View {
    let row: DriftFindingRowModel
    let isResolving: Bool
    let onChoose: (DriftResolutionOption) -> Void
    let onFillValue: (ItemEditorContext) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Image(systemName: row.systemImage)
                    .foregroundStyle(row.isConflict ? Theme.Colors.danger : Theme.Colors.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    Text(verbatim: row.scope)
                        .fxTextStyle(.sectionLabel)
                        .foregroundStyle(Theme.Colors.subtleText)
                    Text(verbatim: row.title)
                        .fxTextStyle(.bodyEmphasized)
                        .foregroundStyle(Theme.Colors.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(row.details, id: \.self) { detail in
                        Text(verbatim: detail)
                            .fxTextStyle(.monoMeta)
                            .foregroundStyle(row.isConflict ? Theme.Colors.danger : Theme.Colors.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                choiceColumn(row.keepLocal)
                choiceColumn(row.acceptGitHub)
            }
            .padding(.leading, Theme.Spacing.xLarge)
        }
    }

    private func choiceColumn(_ choice: DriftChoiceModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Button(choice.title) {
                onChoose(choice.option)
            }
            .fxButtonStyle(.outline)
            .disabled(!choice.isAvailable || isResolving)
            .help(choice.explanation)
            Text(verbatim: choice.unavailableReason ?? choice.explanation)
                .fxTextStyle(.caption)
                .foregroundStyle(choice.isAvailable ? Theme.Colors.mutedText : Theme.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
            if choice.option == .keepLocal, !choice.isAvailable, let fill = row.fillValue {
                Button(String(localized: "drift.fillValue", defaultValue: "Fill Value…")) {
                    onFillValue(fill)
                }
                .fxButtonStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
