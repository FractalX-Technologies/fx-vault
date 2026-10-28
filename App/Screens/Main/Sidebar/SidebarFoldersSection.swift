import SwiftUI
import VaultCore

/// Folders in the sidebar (v0.7.0; board Main2-Home): the header with New Folder (+), one row
/// per folder with its item count and context menu, its subfolders one step in under a chevron,
/// or "New Folder…" when there is none. The search filters folders by name too.
struct SidebarFoldersSection: View {
    let main: MainViewModel

    var body: some View {
        let sidebar = main.sidebar
        let folders = sidebar.visibleFolders
        VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
            SidebarSectionHeader(title: FolderCopy.sectionTitle) {
                Button {
                    main.newFolder()
                } label: {
                    Image(systemName: "plus")
                        .font(Theme.Typography.monoLabel)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .frame(
                            width: Theme.Layout.sidebarSectionHeaderHeight,
                            height: Theme.Layout.sidebarSectionHeaderHeight
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(FolderCopy.newFolder)
                .accessibilityLabel(FolderCopy.newFolder)
            }
            if folders.isEmpty, sidebar.searchText.isEmpty {
                SidebarTreeRow(
                    level: 0,
                    systemImage: "folder.badge.plus",
                    title: FolderCopy.newFolder,
                    isSelected: false,
                    isDimmed: true
                ) {
                    main.newFolder()
                }
            }
            ForEach(folders) { folder in
                let subfolders = sidebar.visibleSubfolders(of: folder.id)
                let isExpanded = sidebar.isExpanded(folder: folder.id)
                row(folder, level: 0, isExpanded: sidebar.subfolderCount(of: folder.id) > 0 ? isExpanded : nil)
                if isExpanded {
                    ForEach(subfolders) { subfolder in
                        row(subfolder, level: 1, isExpanded: nil)
                    }
                }
            }
        }
    }

    private func row(_ folder: FolderModel, level: Int, isExpanded: Bool?) -> some View {
        let sidebar = main.sidebar
        let isSelected = sidebar.selectedFolderID == folder.id
        let counts = PlaceCopy.counts(secrets: folder.secretCount, variables: folder.variableCount)
        let title = sidebar.folderTitle(folder.id)
        return SidebarTreeRow(
            level: level,
            isExpanded: isExpanded,
            systemImage: isSelected ? Theme.Symbols.folderSelected : Theme.Symbols.folder,
            title: folder.name,
            isSelected: isSelected,
            accessibilityID: AccessibilityID.Main.folder(title),
            toggleAccessibilityID: AccessibilityID.Main.folderToggle(title),
            onToggle: { sidebar.toggle(folder: folder.id) }
        ) {
            sidebar.selectedFolderID = folder.id
        } trailing: {
            SidebarCount(value: folder.itemCount, help: counts)
        }
        .help(counts)
        .contextMenu {
            FolderContextMenu(folderID: folder.id, main: main)
        }
    }
}
