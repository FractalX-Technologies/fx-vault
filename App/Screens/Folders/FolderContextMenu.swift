import SwiftUI
import VaultCore

/// A folder's actions (v0.7.0): the sidebar row's context menu and the ••• of its detail
/// header. Send to Teammate lists the teammates nearby (a verified chat opens with the folder
/// attached after Touch ID or the password); Share as File… and Export .env… need items.
struct FolderContextMenu: View {
    let folderID: FolderID
    let main: MainViewModel

    var body: some View {
        let folder = main.sidebar.folder(folderID)
        let hasItems = (folder?.itemCount ?? 0) > 0
        Button(FolderCopy.rename) {
            main.present(.folderName(FolderNameContext(mode: .rename(folderID))))
        }
        Divider()
        let teammates = main.app.teamPresence.people.filter(\.isTeammate)
        Menu(FolderCopy.sendToTeammate) {
            if teammates.isEmpty {
                Text(String(localized: "folder.send.nobody", defaultValue: "No teammate nearby"))
            }
            ForEach(teammates) { person in
                Button(person.name) {
                    main.app.teamPresence.chat(with: person, sendingFolder: folderID)
                }
            }
        }
        .disabled(!hasItems)
        Button(FolderCopy.shareAsFile) {
            main.present(.shareExport(ShareExportContext(selection: .folder(folderID))))
        }
        .disabled(!hasItems)
        Button(FolderCopy.exportEnv) {
            main.present(.envExport(EnvExportContext(folderID: folderID)))
        }
        .disabled(!hasItems)
        Divider()
        Button(FolderCopy.delete, role: .destructive) {
            main.sidebar.pendingFolderDeletion = folder
        }
    }
}
