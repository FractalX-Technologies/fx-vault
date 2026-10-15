import SwiftUI

/// The plan note of environment and branch-policy editors (§2 paid-plan note, §10): hedged copy
/// plus a Learn more link to GitHub's documentation.
struct EnvironmentPlanNoteView: View {
    /// True when GitHub already refused an environment change on this repository's plan.
    let isPlanGated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            ConfigEditorNoteView(note: isPlanGated
                ? .warning(String(
                    localized: "environment.planNote.gated",
                    defaultValue: "GitHub refused an environment change on this repository's plan. Environments and branch rules on private repositories may need a paid GitHub plan."
                ))
                : .info(String(
                    localized: "environment.planNote",
                    defaultValue: "Some environment features on private repositories depend on your GitHub plan."
                )))
            if let url = ExternalLinks.environmentPlans {
                Link(String(localized: "environment.planNote.learnMore", defaultValue: "Learn more"), destination: url)
                    .font(Theme.Typography.caption)
            }
        }
    }
}
