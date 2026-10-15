import SwiftUI

/// After Create: the repository is staged in the vault and Sync creates it on GitHub. Names and
/// counts only.
struct CreateRepoStagedView: View {
    let staged: CreateRepoStagedModel
    let canSyncNow: Bool
    let onSyncNow: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            CardHeader(
                systemImage: "checkmark.circle",
                title: String(localized: "createRepo.staged.title", defaultValue: "\(staged.fullName) is ready to sync"),
                subtitle: String(
                    localized: "createRepo.staged.message",
                    defaultValue: "Nothing is on GitHub yet. The next Sync creates the repository with its environments, secrets and variables in one run."
                )
            )
            Text(verbatim: contentSummary)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textPrimary)
            if let folder = staged.cloneFolder {
                Label(
                    String(
                        localized: "createRepo.staged.clone",
                        defaultValue: "Then Sync clones it into \(folder.path(percentEncoded: false))."
                    ),
                    systemImage: "arrow.down.to.line"
                )
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !staged.strippedTrailingNewlines.isEmpty {
                Label(
                    String(
                        localized: "createRepo.staged.strippedNewlines",
                        defaultValue: "Trailing line breaks were removed from \(staged.strippedTrailingNewlines.joined(separator: ", ")), as GitHub does."
                    ),
                    systemImage: "return"
                )
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(String(localized: "createRepo.staged.syncNow", defaultValue: "Sync Now…"), action: onSyncNow)
                    .disabled(!canSyncNow)
                Button(String(localized: "createRepo.staged.done", defaultValue: "Done"), action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xLarge)
    }

    private var contentSummary: String {
        CreateRepoText.contentSummary(
            environments: staged.environmentCount,
            secrets: staged.secretCount,
            variables: staged.variableCount
        )
    }
}
