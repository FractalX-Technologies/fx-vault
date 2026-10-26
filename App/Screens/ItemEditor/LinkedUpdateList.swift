import SwiftUI
import VaultData

/// The linked copies a new value can update (board Folder-LinkedUpdate): one hairline box of
/// 34 pt rows, each a checkbox, the place's path in mono and how its value compares; a copy that
/// can't take it has no checkbox and says why, muted.
struct LinkedUpdateList: View {
    let copies: [LinkedCopyModel]
    let canEdit: Bool
    let isIncluded: (LinkedCopyModel) -> Binding<Bool>

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        VStack(spacing: 0) {
            ForEach(copies) { copy in
                if copy.id != copies.first?.id {
                    Divider()
                }
                row(copy)
            }
        }
        .background(Theme.Colors.card, in: shape)
        .overlay(shape.strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline))
    }

    private func row(_ copy: LinkedCopyModel) -> some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            if copy.isEditable {
                Toggle(copy.placePath, isOn: isIncluded(copy))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!canEdit)
            }
            Text(verbatim: copy.placePath)
                .fxTextStyle(.monoMeta)
                .foregroundStyle(copy.isEditable ? Theme.Colors.ink : Theme.Colors.subtleText)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityHidden(copy.isEditable)
            Spacer(minLength: Theme.Spacing.small)
            if let blocked = copy.blockedNote {
                Text(blocked)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
            } else {
                LinkedComparisonLabel(comparison: copy.comparison)
            }
        }
        // A row without a checkbox lines its path up with the others' (12 + 14 + 10 pt).
        .padding(.leading, copy.isEditable ? Theme.Spacing.medium : Theme.Layout.linkedUpdateBlockedInset)
        .padding(.trailing, Theme.Spacing.medium)
        .frame(height: Theme.Layout.tableRowHeight)
        .help(copy.editBlock?.presentation.message ?? "")
    }
}

/// "● Same value" (a `success` dot), "○ Differs" (an ink ring, in ink), or the other states with
/// a muted dot.
private struct LinkedComparisonLabel: View {
    let comparison: LinkedValueComparison

    var body: some View {
        HStack(spacing: Theme.Spacing.smallMinus) {
            switch comparison {
            case .same:
                StatusDot(color: Theme.Colors.success)
            case .differs:
                RingDot()
            case .valueMissing:
                StatusDot(color: Theme.Colors.warning)
            case .unknown:
                StatusDot(color: Theme.Colors.hairlineStrong)
            }
            Text(comparison.title)
                .fxTextStyle(.caption)
                .foregroundStyle(comparison == .differs ? Theme.Colors.ink : Theme.Colors.mutedText)
        }
    }
}
