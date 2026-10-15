/// Why an item cannot be opened in the editor beyond the repository's own errors.
enum ItemEditorError: PresentableError {
    /// The item is a tombstone pending deletion on GitHub.
    case deleted

    nonisolated var errorPresentation: ErrorPresentationModel {
        switch self {
        case .deleted:
            ErrorPresentationModel(
                title: String(localized: "itemEditor.deleted.title", defaultValue: "This item is deleted"),
                message: String(
                    localized: "itemEditor.deleted.message",
                    defaultValue: "It is pending deletion on GitHub. Revert it in the table to edit it again."
                )
            )
        }
    }
}
