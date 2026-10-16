import SwiftUI
import VaultCore

/// The FOLDERS section at the top of the sidebar (v0.7.0, tasks/todo.md F3): the label with
/// New Folder (+), one row per folder (symbol, name, item count; `surface2` when selected) with
/// its context menu, or "New Folder…" when there is none. The search field filters folders by
/// name too.
struct SidebarFoldersSection: View {
    let main: MainViewModel

    var body: some View {
        let sidebar = main.sidebar
        let folders = sidebar.visibleFolders
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            HStack(spacing: Theme.Spacing.small) {
                SectionLabel(FolderCopy.sectionTitle)
                Spacer(minLength: 0)
                Button {
                    main.newFolder()
                } label: {
                    Image(systemName: "plus")
                        .font(Theme.Typography.monoLabel)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .frame(width: Theme.Layout.avatarSize, height: Theme.Layout.avatarSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(FolderCopy.newFolder)
                .accessibilityLabel(FolderCopy.newFolder)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.bottom, Theme.Spacing.xSmall)
            if folders.isEmpty, sidebar.searchText.isEmpty {
                Button {
                    main.newFolder()
                } label: {
                    Label(FolderCopy.newFolder, systemImage: "folder.badge.plus")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .fxRowBackground(isSelected: false, style: .sidebar)
                }
                .buttonStyle(.plain)
            }
            ForEach(folders) { folder in
                Button {
                    sidebar.selectedFolderID = folder.id
                } label: {
                    SidebarFolderRow(folder: folder, isSelected: sidebar.selectedFolderID == folder.id)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    FolderContextMenu(folderID: folder.id, main: main)
                }
            }
        }
    }
}

/// One folder (32 pt): the folder symbol, its name and the number of items in mono.
private struct SidebarFolderRow: View {
    let folder: FolderModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            Image(systemName: isSelected ? "folder.fill" : "folder")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink)
                .accessibilityHidden(true)
            Text(verbatim: folder.name)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(verbatim: "\(folder.itemCount)")
                .font(Theme.Typography.monoLabel)
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityLabel(FolderCopy.counts(secrets: folder.secretCount, variables: folder.variableCount))
        }
        .fxRowBackground(isSelected: isSelected, style: .sidebar)
        .help(FolderCopy.counts(secrets: folder.secretCount, variables: folder.variableCount))
    }
}
