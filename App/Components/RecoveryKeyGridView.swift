import SwiftUI
import VaultCore

/// The recovery key as 14 numbered groups of 4 on two rows (§5.3), in Geist Mono on a hairline
/// container. The window it appears in is excluded from screen capture while it is visible.
struct RecoveryKeyGridView: View {
    let groups: [String]

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Theme.Spacing.small),
            count: Theme.Layout.recoveryKeyColumns
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.small) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                VStack(spacing: Theme.Spacing.xSmall) {
                    Text(verbatim: StepCounter.padded(index + 1))
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.subtleText)
                    Text(verbatim: group)
                        .fxTextStyle(.mono)
                        .foregroundStyle(Theme.Colors.ink)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.small)
                .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.compactRow, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    String(localized: "recoveryKey.group.accessibility", defaultValue: "Group \(index + 1): \(group)")
                )
            }
        }
        .padding(Theme.Spacing.medium)
        .fxCardBackground(.container)
        .screenCaptureProtected()
    }
}

#Preview {
    RecoveryKeyGridView(groups: Array(repeating: "ABCD", count: Limits.recoveryKeyGroupCount))
        .padding()
        .frame(width: Theme.Layout.cardWidth)
}
