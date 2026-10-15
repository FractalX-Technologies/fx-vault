import SwiftUI
import VaultData

/// The drift banner in the repository header (§10 Column 3): "3 changes on GitHub · Review".
///
/// UI feature contract entry view (ARCHITECTURE.md): `RepoDetailScreen` shows it when the last
/// drift check of the open repository found something (`report.count > 0`) and calls
/// `onReview` to present `MainSheet.driftReview`. The init signature is fixed.
///
/// FractalX `Banner` (mockup Main): `.info` with the brand dot and a Review link; `.warning` when a
/// change on GitHub also changed in the vault (a conflict needs a decision, nothing failed).
struct DriftBannerView: View {
    private let report: DriftReportModel
    private let onReview: () -> Void

    init(report: DriftReportModel, onReview: @escaping () -> Void) {
        self.report = report
        self.onReview = onReview
    }

    var body: some View {
        Banner(
            Self.tone(conflictCount: report.conflicts.count),
            message: Self.message(count: report.count, conflictCount: report.conflicts.count),
            systemImage: report.conflicts.isEmpty ? nil : "exclamationmark.arrow.triangle.2.circlepath",
            action: .init(title: String(localized: "drift.banner.review", defaultValue: "Review"), handler: onReview)
        )
        .help(String(
            localized: "drift.banner.review.help",
            defaultValue: "Keep your version or take GitHub's for each change"
        ))
    }

    // MARK: Resolution (pure)

    static func tone(conflictCount: Int) -> Banner.Tone {
        conflictCount > 0 ? .warning : .info
    }

    /// "3 changes on GitHub", plus "· 1 also changed in your vault" when there are conflicts.
    static func message(count: Int, conflictCount: Int) -> String {
        let title = DriftCopy.bannerTitle(count: count)
        guard conflictCount > 0 else { return title }
        return String(
            localized: "drift.banner.withConflicts",
            defaultValue: "\(title) · \(DriftCopy.bannerConflicts(conflictCount))"
        )
    }
}
