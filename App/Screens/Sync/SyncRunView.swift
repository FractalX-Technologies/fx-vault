import SwiftUI

/// Step 3: n of m, the change in flight (name only), the write limit and Cancel (in the footer).
struct SyncRunView: View {
    let progress: SyncRunProgressModel
    let writeBudgetLine: String?

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Spacer()
            ProgressView(value: progress.fraction)
                .frame(width: Theme.Layout.syncProgressWidth)
                .accessibilityLabel(countText)
            Text(verbatim: countText)
                .font(Theme.Typography.headline.monospacedDigit())
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(verbatim: phaseText)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let writeBudgetLine {
                Text(verbatim: writeBudgetLine)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .help(SyncCopy.writeBudgetHelp)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xLarge)
    }

    private var countText: String {
        String(localized: "sync.progress.count", defaultValue: "\(progress.completed) of \(progress.total)")
    }

    private var phaseText: String {
        if progress.isCancelling {
            return String(
                localized: "sync.progress.cancelling",
                defaultValue: "Stopping after the current GitHub call…"
            )
        }
        switch progress.phase {
        case .starting:
            return String(localized: "sync.progress.starting", defaultValue: "Starting…")
        case .writing:
            guard let name = progress.currentName else {
                return String(localized: "sync.progress.writing", defaultValue: "Writing to GitHub…")
            }
            return String(localized: "sync.progress.current", defaultValue: "Syncing \(name)…")
        case .verifying(let scope):
            return String(localized: "sync.progress.verifying", defaultValue: "Confirming the changes in \(scope)…")
        case .cloning:
            return String(localized: "sync.progress.cloning", defaultValue: "Cloning the new repository…")
        }
    }
}
