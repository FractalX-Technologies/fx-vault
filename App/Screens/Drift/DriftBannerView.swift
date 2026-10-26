import SwiftUI
import VaultData

/// The drift line under a repository's header (§10 Column 3; board Main2-Repository): the ring,
/// "2 changed on GitHub", "· 1 also changed in your vault" in the warning color when a change on
/// GitHub also changed in the vault (a decision is needed; nothing failed), then Review.
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
        let conflictCount = report.conflicts.count
        HStack(spacing: Theme.Spacing.smallMinus) {
            ChangedOnGitHubDot()
            Text(Self.message(count: report.count, conflictCount: conflictCount))
                .fxTextStyle(.caption)
                .foregroundStyle(Self.tone(conflictCount: conflictCount) == .warning ? Theme.Colors.warning : Theme.Colors.mutedText)
                .lineLimit(1)
            Text(verbatim: "·")
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .accessibilityHidden(true)
            Button(PlaceCopy.review, action: onReview)
                .fxLinkButtonStyle(isEmphasized: true)
                .help(String(
                    localized: "drift.banner.review.help",
                    defaultValue: "Keep your version or take GitHub's for each change"
                ))
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Resolution (pure)

    static func tone(conflictCount: Int) -> Banner.Tone {
        conflictCount > 0 ? .warning : .info
    }

    /// "3 changed on GitHub", plus "· 1 also changed in your vault" when there are conflicts.
    static func message(count: Int, conflictCount: Int) -> String {
        let title = PlaceCopy.changedOnGitHub(count)
        guard conflictCount > 0 else { return title }
        return String(
            localized: "drift.banner.withConflicts",
            defaultValue: "\(title) · \(DriftCopy.bannerConflicts(conflictCount))"
        )
    }
}
