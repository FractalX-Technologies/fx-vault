import SwiftUI
import VaultCore

/// Column 2 for a folder (v0.7.0): FOLDER, the folder as the one selected row with its counts,
/// its actions as quiet rows, and how its items reach repositories.
struct FolderOverviewView: View {
    let folder: FolderModel
    let main: MainViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                SectionLabel(FolderCopy.eyebrow)
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.bottom, Theme.Spacing.small)
                HStack(spacing: Theme.Spacing.mediumMinus) {
                    Image(systemName: "folder")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                        Text(verbatim: folder.name)
                            .font(Theme.Typography.calloutEmphasized)
                            .foregroundStyle(Theme.Colors.ink)
                            .lineLimit(1)
                        Text(FolderCopy.counts(secrets: folder.secretCount, variables: folder.variableCount))
                            .fxTextStyle(.monoMeta)
                            .foregroundStyle(Theme.Colors.mutedText)
                            .lineLimit(1)
                    }
                    .padding(.vertical, Theme.Spacing.xSmall)
                    Spacer(minLength: 0)
                }
                .fxRowBackground(isSelected: true, style: .scope)
                Text(folder.itemCount == 0 ? FolderCopy.emptyHint : FolderCopy.overviewHint)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.top, Theme.Spacing.medium)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.largePlus)
        }
        .background(Theme.Colors.ground)
        .contextMenu {
            FolderContextMenu(folderID: folder.id, main: main)
        }
    }
}
