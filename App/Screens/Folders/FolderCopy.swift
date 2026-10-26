import Foundation

/// The texts of folders (v0.7.0), in one place for the sidebar, the folder columns and sheets.
enum FolderCopy {
    static let sectionTitle = String(localized: "folder.section", defaultValue: "Folders")
    static let eyebrow = String(localized: "folder.eyebrow", defaultValue: "Folder")
    static let newFolder = String(localized: "folder.new", defaultValue: "New Folder…")
    static let rename = String(localized: "folder.rename", defaultValue: "Rename…")
    static let delete = String(localized: "folder.delete", defaultValue: "Delete Folder…")
    static let exportEnv = String(localized: "folder.exportEnv", defaultValue: "Export .env…")
    static let emptyHint = String(
        localized: "folder.emptyHint",
        defaultValue: "Keep secrets and variables you use in several repositories here, for example the keys of a mobile app."
    )
    static let nameField = String(localized: "folder.name.field", defaultValue: "Name")
    static let namePrompt = String(localized: "folder.name.prompt", defaultValue: "Mobile App")
    static let nameTaken = String(localized: "folder.name.taken", defaultValue: "Another folder already has this name.")
    static let create = String(localized: "folder.name.create", defaultValue: "Create")
    static let renameSubmit = String(localized: "folder.name.rename", defaultValue: "Rename")
    static let newTitle = String(localized: "folder.name.newTitle", defaultValue: "New Folder")
    static let renameTitle = String(localized: "folder.name.renameTitle", defaultValue: "Rename Folder")

    static func deleteTitle(_ name: String) -> String {
        String(localized: "folder.delete.title", defaultValue: "Delete the folder \(name)?")
    }

    static let deleteConfirm = String(localized: "folder.delete.confirm", defaultValue: "Delete Folder")
    static let deleteMessage = String(
        localized: "folder.delete.message",
        defaultValue: "Its secrets and variables are removed from this Mac. Copies you pasted into repositories stay where they are."
    )

    static func deleteItemsTitle(count: Int) -> String {
        count == 1
            ? String(localized: "folder.deleteItems.title.one", defaultValue: "Delete this item?")
            : String(localized: "folder.deleteItems.title", defaultValue: "Delete \(count) items?")
    }

    static func deleteItemsConfirm(count: Int) -> String {
        count == 1
            ? String(localized: "main.detail.delete.confirm", defaultValue: "Delete")
            : String(localized: "main.detail.delete.several.confirm", defaultValue: "Delete \(count) Items")
    }

    static let deleteItemsMessage = String(
        localized: "folder.deleteItems.message",
        defaultValue: "They are removed from this folder now. Copies in repositories and other folders stay."
    )

    /// "3 secrets · 1 variable" (automatic grammar agreement).
    static func counts(secrets: Int, variables: Int) -> String {
        String(AttributedString(
            localized: "folder.counts",
            defaultValue: "^[\(secrets) secret](inflect: true) · ^[\(variables) variable](inflect: true)"
        ).characters)
    }

    static let sendFolder = String(localized: "folder.sendFolder", defaultValue: "Send Folder")
}
