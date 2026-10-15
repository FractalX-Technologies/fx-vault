import SwiftUI
import VaultData

/// The drift banner in the repository header (§10 Column 3): "3 changes on GitHub — Review".
///
/// UI feature contract entry view (ARCHITECTURE.md): `RepoDetailScreen` shows it when the last
/// drift check of the open repository found something (`report.count > 0`) and calls
/// `onReview` to present `MainSheet.driftReview`. The init signature is fixed.
struct DriftBannerView: View {
    private let report: DriftReportModel
    private let onReview: () -> Void

    init(report: DriftReportModel, onReview: @escaping () -> Void) {
        self.report = report
        self.onReview = onReview
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(Theme.Colors.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(verbatim: DriftCopy.bannerTitle(count: report.count))
                    .font(Theme.Typography.callout.weight(.medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
                if !report.conflicts.isEmpty {
                    Text(verbatim: DriftCopy.bannerConflicts(report.conflicts.count))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.danger)
                }
            }
            Spacer()
            Button(String(localized: "drift.banner.review", defaultValue: "Review"), action: onReview)
                .help(String(
                    localized: "drift.banner.review.help",
                    defaultValue: "Keep your version or take GitHub's for each change"
                ))
        }
        .padding(Theme.Spacing.small)
        .background(
            Theme.Colors.warning.opacity(Theme.Opacity.chipBackground),
            in: RoundedRectangle(cornerRadius: Theme.Radius.medium)
        )
        .accessibilityElement(children: .combine)
    }
}
