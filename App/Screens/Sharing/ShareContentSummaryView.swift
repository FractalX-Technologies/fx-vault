import SharingKit
import SwiftUI
import VaultData

/// What a share contains, per scope (v0.2.0): the repository level, then each environment with
/// its counts and whether its branch policy is included. Names and counts only, never values.
/// Used by Share › File… and Share › Nearby….
struct ShareContentSummaryView: View {
    let preview: ShareExportPreviewModel

    var body: some View {
        let lines = ShareSummaryLineModel.lines(for: preview.summary)
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(String(
                localized: "share.summary.title",
                defaultValue: "From \(preview.repositoryFullName)"
            ))
            .fxTextStyle(.sectionLabel)
            .foregroundStyle(Theme.Colors.subtleText)
            .lineLimit(1)
            .truncationMode(.middle)
            if !lines.isEmpty {
                Card(.container, spacing: 0) {
                    Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.large, verticalSpacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            if index > 0 {
                                GridRow {
                                    HairlineDivider()
                                        .gridCellColumns(2)
                                }
                            }
                            GridRow {
                                Text(verbatim: line.scope)
                                    .fxTextStyle(.statusLine)
                                    .foregroundStyle(Theme.Colors.subtleText)
                                    .lineLimit(1)
                                    .padding(.leading, Theme.Spacing.large)
                                    .padding(.vertical, Theme.Spacing.medium)
                                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                                    Text(line.counts)
                                        .fxTextStyle(.calloutEmphasized)
                                        .foregroundStyle(Theme.Colors.ink)
                                    if let policy = line.policy {
                                        Text(policy)
                                            .fxTextStyle(.caption)
                                            .foregroundStyle(Theme.Colors.mutedText)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, Theme.Spacing.large)
                                .padding(.vertical, Theme.Spacing.medium)
                            }
                        }
                    }
                }
            }
            if !preview.valueMissingNames.isEmpty {
                ShareNoteView(
                    systemImage: "exclamationmark.triangle",
                    text: String(
                        localized: "shareExport.summary.valueMissing",
                        defaultValue: "\(preview.valueMissingNames.count) secrets have no value in your vault and are shared by name only."
                    ),
                    tint: Theme.Colors.warning
                )
            }
        }
    }
}

/// One line of ``ShareContentSummaryView``: a scope, its counts and its policy note.
struct ShareSummaryLineModel: Identifiable, Equatable {
    /// Nil for the repository level.
    let environmentName: String?
    let scope: String
    let counts: String
    /// Environments only: whether the branch policy travels.
    let policy: String?

    var id: String {
        environmentName.map { "environment/\($0)" } ?? "repository"
    }

    /// The repository level (when it has items), then every environment.
    static func lines(for summary: ShareContentSummaryModel) -> [ShareSummaryLineModel] {
        var lines: [ShareSummaryLineModel] = []
        if summary.repositoryLevel.total > 0 {
            lines.append(ShareSummaryLineModel(
                environmentName: nil,
                scope: String(localized: "share.summary.repositoryLevel", defaultValue: "Repository level"),
                counts: counts(summary.repositoryLevel),
                policy: nil
            ))
        }
        for environment in summary.environments {
            lines.append(ShareSummaryLineModel(
                environmentName: environment.name,
                scope: environment.name,
                counts: counts(environment.counts),
                policy: environment.includesBranchPolicy
                    ? String(localized: "share.summary.policyIncluded", defaultValue: "with branch policy")
                    : String(localized: "share.summary.policyNotIncluded", defaultValue: "selected items, no branch policy")
            ))
        }
        return lines
    }

    static func counts(_ counts: ShareItemCountModel) -> String {
        String(
            localized: "share.summary.counts",
            defaultValue: "Secrets: \(counts.secrets) · Variables: \(counts.variables)"
        )
    }
}
