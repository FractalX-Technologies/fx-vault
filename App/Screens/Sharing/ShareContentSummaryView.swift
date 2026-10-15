import SharingKit
import SwiftUI
import VaultData

/// What a share contains, per scope (v0.2.0): the repository level, then each environment with
/// its counts and whether its branch policy is included. Names and counts only, never values.
/// Used by Share › File… and Share › Nearby….
struct ShareContentSummaryView: View {
    let preview: ShareExportPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            ShareNoteView(
                systemImage: "shippingbox",
                text: String(
                    localized: "share.summary.title",
                    defaultValue: "From \(preview.repositoryFullName)"
                )
            )
            ForEach(ShareSummaryLineModel.lines(for: preview.summary)) { line in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Image(systemName: line.systemImage)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .accessibilityHidden(true)
                    Text(verbatim: line.scope)
                        .font(Theme.Typography.callout.weight(.semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(line.counts)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    if let policy = line.policy {
                        Text(policy)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
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

    var systemImage: String {
        environmentName == nil ? "folder" : "square.stack.3d.up"
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
