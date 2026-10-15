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
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Image(systemName: row.systemImage)
                    .foregroundStyle(row.isConflict ? Theme.Colors.danger : Theme.Colors.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text(verbatim: row.title)
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .textSelection(.enabled)
                    Text(verbatim: row.scope)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    ForEach(row.details, id: \.self) { detail in
                        Text(verbatim: detail)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(row.isConflict ? Theme.Colors.danger : Theme.Colors.textSecondary)
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
        .padding(.vertical, Theme.Spacing.xSmall)
    }

    private func choiceColumn(_ choice: DriftChoiceModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            Button(choice.title) {
                onChoose(choice.option)
            }
            .disabled(!choice.isAvailable || isResolving)
            .help(choice.explanation)
            Text(verbatim: choice.unavailableReason ?? choice.explanation)
                .font(Theme.Typography.caption)
                .foregroundStyle(choice.isAvailable ? Theme.Colors.textSecondary : Theme.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
            if choice.option == .keepLocal, !choice.isAvailable, let fill = row.fillValue {
                Button(String(localized: "drift.fillValue", defaultValue: "Fill Value…")) {
                    onFillValue(fill)
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
