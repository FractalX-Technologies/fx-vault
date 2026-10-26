import SwiftUI
import VaultData

/// The drift line under a repository's header (§10 Column 3; board Main2-Repository): the ink
/// ring, "2 changed on GitHub" in muted text, "· 1 also changed in your vault" when a change on
/// GitHub also changed in the vault (a decision is needed; nothing failed), then Review in ink.
///
/// UI feature contract entry view (ARCHITECTURE.md): `RepoDetailScreen` shows it when the last
/// drift check of the open repository found something (`report.count > 0`) and calls
/// `onReview` to present `MainSheet.driftReview`. The init signature is fixed.
struct DriftBannerView: View {
    private let message: String
    private let reviewHelp: String
    private let onReview: () -> Void

    init(report: DriftReportModel, onReview: @escaping () -> Void) {
        self.init(
            message: Self.message(count: report.count, conflictCount: report.conflicts.count),
            reviewHelp: String(localized: "drift.banner.review.help", defaultValue: "Keep your version or take GitHub's for each change"),
            onReview: onReview
        )
    }

    /// The same line for a Key Vault's Refresh (board KV-Place): "2 changed in Key Vault".
    init(message: String, reviewHelp: String, onReview: @escaping () -> Void) {
        self.message = message
        self.reviewHelp = reviewHelp
        self.onReview = onReview
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.smallMinus) {
            RingDot()
            Text(message)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .lineLimit(1)
            Text(verbatim: "·")
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .accessibilityHidden(true)
            // Ink with a faint underline as the board, not the brand link of sheets.
            Button(action: onReview) {
                Text(PlaceCopy.review)
                    .font(Theme.Typography.captionEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                    .underline(color: Theme.Colors.hairlineStrong)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(reviewHelp)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Resolution (pure)

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
