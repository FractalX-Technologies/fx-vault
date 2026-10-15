import SwiftUI

/// After Create: the repository is staged in the vault and Sync creates it on GitHub. Names and
/// counts only.
struct CreateRepoStagedView: View {
    let staged: CreateRepoStagedModel
    let canSyncNow: Bool
    /// Why Sync Now… is disabled (offline), shown under the buttons.
    let syncNowUnavailableReason: String?
    let onSyncNow: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(
                label: String(localized: "createRepo.staged.eyebrow", defaultValue: "Ready to sync"),
                title: String(localized: "createRepo.staged.title", defaultValue: "\(staged.fullName) is ready to sync"),
                subtitle: String(
                    localized: "createRepo.staged.message",
                    defaultValue: "Nothing is on GitHub yet. The next Sync creates the repository with its environments, secrets and variables in one run."
                )
            )
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Label {
                    Text(verbatim: contentSummary)
                        .fxTextStyle(.monoMeta)
                        .foregroundStyle(Theme.Colors.ink)
                } icon: {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Theme.Colors.success)
                }
                if let folder = staged.cloneFolder {
                    Label(
                        String(
                            localized: "createRepo.staged.clone",
                            defaultValue: "Then Sync clones it into \(folder.path(percentEncoded: false))."
                        ),
                        systemImage: "arrow.down.to.line"
                    )
                    .fxTextStyle(.callout)
                    .foregroundStyle(Theme.Colors.mutedText)
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
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .configSheetRowPadding()
            .fxCardBackground(.container)
            HStack(spacing: Theme.Spacing.mediumMinus) {
                Group {
                    if let syncNowUnavailableReason {
                        Text(syncNowUnavailableReason)
                            .fxTextStyle(.caption)
                            .foregroundStyle(Theme.Colors.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(String(localized: "createRepo.staged.syncNow", defaultValue: "Sync Now…"), action: onSyncNow)
                    .fxButtonStyle(.secondary, size: .large)
                    .disabled(!canSyncNow)
                Button(String(localized: "createRepo.staged.done", defaultValue: "Done"), action: onDone)
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xxLarge)
    }

    private var contentSummary: String {
        CreateRepoText.contentSummary(
            environments: staged.environmentCount,
            secrets: staged.secretCount,
            variables: staged.variableCount
        )
    }
}
