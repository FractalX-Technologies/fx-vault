import Foundation
import VaultCore
import VaultData

/// The texts of folders (v0.7.0), in one place for the sidebar, the folder columns and sheets.
enum FolderCopy {
    static let sectionTitle = String(localized: "folder.section", defaultValue: "Folders")
    /// One key with the place header's kind.
    static let eyebrow = PlaceCopy.folder
    static let newFolder = String(localized: "folder.new", defaultValue: "New Folder…")
    static let newSubfolder = String(localized: "folder.newSubfolder", defaultValue: "New Subfolder…")
    static let rename = String(localized: "folder.rename", defaultValue: "Rename…")
    static let delete = String(localized: "folder.delete", defaultValue: "Delete Folder…")
    static let exportEnv = PlaceCopy.exportEnv
    static let emptyHint = String(
        localized: "folder.emptyHint",
        defaultValue: "Keep secrets and variables you use in several repositories here, for example the keys of a mobile app."
    )
    static let nameField = String(localized: "folder.name.field", defaultValue: "Name")
    static let namePrompt = String(localized: "folder.name.prompt", defaultValue: "Mobile App")
    static let nameTaken = String(localized: "folder.name.taken", defaultValue: "Another folder here already has this name.")
    static let create = String(localized: "folder.name.create", defaultValue: "Create")
    static let renameSubmit = String(localized: "folder.name.rename", defaultValue: "Rename")
    static let newTitle = String(localized: "folder.name.newTitle", defaultValue: "New Folder")
    static let renameTitle = String(localized: "folder.name.renameTitle", defaultValue: "Rename Folder")

    static func newSubfolderTitle(_ parent: String) -> String {
        String(localized: "folder.name.newSubfolderTitle", defaultValue: "New Subfolder in \(parent)")
    }

    static func deleteTitle(_ name: String) -> String {
        String(localized: "folder.delete.title", defaultValue: "Delete the folder \(name)?")
    }

    static let deleteConfirm = String(localized: "folder.delete.confirm", defaultValue: "Delete Folder")
    static let deleteMessage = String(
        localized: "folder.delete.message",
        defaultValue: "Its secrets and variables are removed from this Mac. Copies you pasted into repositories stay where they are."
    )

    /// A folder with subfolders: they go with it, and so do the files it and they keep (v23).
    static func deleteMessage(subfolders: Int, files: Int = 0) -> String {
        let message = subfolders > 0
            ? String(inflected: AttributedString(
                localized: "folder.delete.messageWithSubfolders",
                defaultValue: "Its ^[\(subfolders) subfolder](inflect: true), secrets and variables are removed from this Mac. Copies you pasted into repositories stay where they are."
            ))
            : deleteMessage
        guard files > 0 else { return message }
        let filesText = files == 1
            ? String(localized: "folder.delete.files.one", defaultValue: "The file kept in it is deleted too.")
            : String(localized: "folder.delete.files", defaultValue: "The \(files) files kept in it are deleted too.")
        return message + " " + filesText
    }

    static func deleteItemsMessage(count: Int) -> String {
        count == 1
            ? String(
                localized: "folder.deleteItems.message.one",
                defaultValue: "It’s removed from this folder now. Copies in repositories and other folders stay."
            )
            : String(
                localized: "folder.deleteItems.message",
                defaultValue: "They are removed from this folder now. Copies in repositories and other folders stay."
            )
    }

    static let sendFolder = String(localized: "folder.sendFolder", defaultValue: "Send Folder")
}

/// The texts of folder files (v23): the Files section, its sheets and the drop overlay.
enum FolderFileCopy {
    static let addFile = String(localized: "folderFile.add", defaultValue: "Add File…")
    static let saveAs = String(localized: "folderFile.saveAs", defaultValue: "Save As…")
    static let rename = String(localized: "folderFile.rename", defaultValue: "Rename…")
    static let renameTitle = String(localized: "folderFile.rename.title", defaultValue: "Rename File")
    static let renameSubmit = String(localized: "folderFile.rename.submit", defaultValue: "Rename")
    static let delete = String(localized: "folderFile.delete", defaultValue: "Delete…")
    static let deleteConfirm = String(localized: "folderFile.delete.confirm", defaultValue: "Delete File")
    static let deleteMessage = String(
        localized: "folderFile.delete.message",
        defaultValue: "The file is removed from FX Vault. Copies you saved stay where they are."
    )
    static let dropTitle = String(localized: "folderFile.drop.title", defaultValue: "Drop to add to this folder")

    /// "1 file", "2 files" (the folder's subline).
    static func count(_ count: Int) -> String {
        String(inflected: AttributedString(localized: "folderFile.count", defaultValue: "^[\(count) file](inflect: true)"))
    }

    static func sectionTitle(count: Int) -> String {
        String(localized: "folderFile.section", defaultValue: "Files · \(count)")
    }

    static func deleteTitle(_ name: String) -> String {
        String(localized: "folderFile.delete.title", defaultValue: "Delete \(name)?")
    }

    static func saveTitle(_ name: String) -> String {
        String(localized: "folderFile.save.title", defaultValue: "Save \(name)")
    }

    static let saveMessage = String(
        localized: "folderFile.save.message",
        defaultValue: "The file is saved unencrypted where you chose. Confirm it's you."
    )

    static func added(_ name: String) -> String {
        String(localized: "folderFile.added", defaultValue: "Added \(name).")
    }

    static func saved(_ name: String) -> String {
        String(localized: "folderFile.saved", defaultValue: "Saved \(name).")
    }

    static func dropDetail(secretLimit: Int) -> String {
        String(
            localized: "folderFile.drop.detail",
            defaultValue: "\(FileSecretCopy.droppableExtensions) up to \(size(secretLimit)) become file secrets · any other file up to \(limit()) is kept as a file"
        )
    }

    /// "4 KB", "12.3 MB", as Finder shows sizes. Nonisolated: error messages use it.
    nonisolated static func size(_ byteCount: Int) -> String {
        Int64(byteCount).formatted(.byteCount(style: .file))
    }

    /// "50 MB": ``Limits/maxFolderFileBytes`` is 50 MiB, which the decimal style of ``size(_:)``
    /// would write as 52.4 MB.
    nonisolated static func limit(_ byteCount: Int = Limits.maxFolderFileBytes) -> String {
        Int64(byteCount).formatted(.byteCount(style: .memory))
    }
}

/// Localized text for folder file failures. Messages never include names or contents.
nonisolated extension FolderFileError: PresentableError {
    var errorPresentation: ErrorPresentationModel {
        switch self {
        case .config(let error):
            error.presentation
        case .tooLarge, .unreadable:
            ErrorPresentationModel(
                title: String(localized: "error.folderFile.read.title", defaultValue: "The file was not added"),
                message: localizedMessage
            )
        case .write, .authorizationInvalid, .quarantine:
            ErrorPresentationModel(
                title: String(localized: "error.folderFile.write.title", defaultValue: "The file was not saved"),
                message: localizedMessage
            )
        }
    }

    var localizedMessage: String {
        switch self {
        case .tooLarge(let limit):
            String(
                localized: "error.folderFile.tooLarge",
                defaultValue: "The file is larger than \(FolderFileCopy.limit(limit)). A folder keeps files up to that size."
            )
        case .unreadable:
            String(
                localized: "error.folderFile.unreadable",
                defaultValue: "FX Vault cannot open this file. Check that it is a file you can read, not a folder."
            )
        case .authorizationInvalid:
            String(
                localized: "error.folderFile.authorizationInvalid",
                defaultValue: "Each save needs a fresh Touch ID or master password check. Confirm it's you and try again."
            )
        case .write(let error):
            error.envFileMessage
        case .quarantine:
            String(
                localized: "error.folderFile.quarantine",
                defaultValue: "macOS could not mark the file as downloaded, so FX Vault removed it. Save it to a folder on your Mac's disk."
            )
        case .config(let error):
            error.localizedMessage
        }
    }
}
