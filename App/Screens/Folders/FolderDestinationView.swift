import SwiftUI
import VaultCore
import VaultData

/// The destination of a received copy of a folder (``FolderDestinationModel``): what arrived,
/// then Save as Folder or Import Into a Repository with their choices.
struct FolderDestinationView: View {
    @Bindable var model: FolderDestinationModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            HStack(spacing: Theme.Spacing.mediumMinus) {
                Image(systemName: Theme.Symbols.folder)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.ink)
                    .accessibilityHidden(true)
                Text(verbatim: model.senderFolderName)
                    .fxTextStyle(.calloutEmphasized)
                    .foregroundStyle(Theme.Colors.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(PlaceCopy.counts(secrets: model.secretCount, variables: model.variableCount))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
            .padding(Theme.Spacing.medium)
            .fxCardBackground(.container)
            SegmentedPill(
                selection: $model.choice,
                segments: [
                    .init(value: FolderDestinationModel.Choice.folder, title: FolderDestinationCopy.saveAsFolder),
                    .init(value: .repository, title: FolderDestinationCopy.importIntoRepository, isEnabled: !model.repositories.isEmpty),
                ],
                accessibilityLabel: FolderDestinationCopy.destination
            )
            .fixedSize()
            switch model.choice {
            case .folder:
                folderFields
            case .repository:
                repositoryFields
            }
        }
    }

    @ViewBuilder
    private var folderFields: some View {
        ConfigSheetField(FolderDestinationCopy.folder) {
            Picker(FolderDestinationCopy.folder, selection: $model.folderChoice) {
                Text(FolderDestinationCopy.newFolder).tag(FolderDestinationModel.FolderChoice.new)
                if !model.folders.isEmpty {
                    Divider()
                    ForEach(model.folders) { folder in
                        Text(verbatim: model.folderTitles[folder.id] ?? folder.name).tag(FolderDestinationModel.FolderChoice.existing(folder.id))
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        if model.folderChoice == .new {
            ConfigSheetField(FolderCopy.nameField) {
                TextField(FolderCopy.nameField, text: $model.newFolderName)
                    .autocorrectionDisabled()
                    .labelsHidden()
                    .fxInputField(.rounded, isFocused: false, isInvalid: model.newFolderNameNote != nil)
                if let note = model.newFolderNameNote {
                    ConfigEditorNoteView(note: note)
                }
            }
        } else {
            ConfigSheetField(FolderDestinationCopy.sameNames) {
                Picker(FolderDestinationCopy.sameNames, selection: $model.replacesExisting) {
                    Text(FolderDestinationCopy.keepMine).tag(false)
                    Text(FolderDestinationCopy.replace).tag(true)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }
        }
        SheetCallout(systemImage: "info.circle", tint: Theme.Colors.subtleText, text: FolderDestinationCopy.folderNote)
    }

    @ViewBuilder
    private var repositoryFields: some View {
        ConfigSheetField(FolderDestinationCopy.repository) {
            Picker(FolderDestinationCopy.repository, selection: $model.repositoryID) {
                Text(FolderDestinationCopy.chooseRepository).tag(RepoID?.none)
                ForEach(model.repositories) { repository in
                    Text(verbatim: repository.fullName).tag(RepoID?.some(repository.id))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        if !model.scopes.isEmpty {
            ConfigSheetField(FolderDestinationCopy.scope) {
                Picker(FolderDestinationCopy.scope, selection: $model.scope) {
                    ForEach(model.scopes) { summary in
                        Text(verbatim: summary.title)
                            .tag(summary.scope)
                            .selectionDisabled(model.readOnlyReason(for: summary) != nil)
                    }
                }
                .labelsHidden()
                .fixedSize()
                if let summary = model.scopes.first(where: { $0.scope == model.scope }), let reason = model.readOnlyReason(for: summary) {
                    ConfigEditorNoteView(note: .error(reason.localizedExplanation))
                }
            }
        }
        SheetCallout(systemImage: "info.circle", tint: Theme.Colors.subtleText, text: FolderDestinationCopy.repositoryNote)
    }
}

/// The texts of ``FolderDestinationView``.
enum FolderDestinationCopy {
    static let destination = String(localized: "folder.destination", defaultValue: "Destination")
    static let saveAsFolder = String(localized: "folder.destination.saveAsFolder", defaultValue: "Save as Folder")
    static let importIntoRepository = String(localized: "folder.destination.importInto", defaultValue: "Import Into a Repository")
    static let folder = String(localized: "folder.destination.folder", defaultValue: "Folder")
    static let newFolder = String(localized: "folder.destination.newFolder", defaultValue: "New folder")
    static let sameNames = String(localized: "folder.destination.sameNames", defaultValue: "Names the folder already has")
    static let keepMine = String(localized: "folder.destination.keepMine", defaultValue: "Keep mine")
    static let replace = String(localized: "folder.destination.replace", defaultValue: "Replace with the received values")
    static let repository = String(localized: "folder.destination.repository", defaultValue: "Repository")
    static let chooseRepository = String(localized: "folder.destination.chooseRepository", defaultValue: "Choose a repository")
    static let scope = String(localized: "folder.destination.scope", defaultValue: "Scope")
    static let folderNote = String(
        localized: "folder.destination.folderNote",
        defaultValue: "The items are saved in your vault at once. Each person keeps their own copy: later changes are not sent automatically."
    )
    static let repositoryNote = String(
        localized: "folder.destination.repositoryNote",
        defaultValue: "You review everything before it is imported. The items become changes for your next Sync; nothing reaches GitHub before that."
    )
    static let continueTitle = String(localized: "folder.destination.continue", defaultValue: "Continue")
    static let saveTitle = String(localized: "folder.destination.save", defaultValue: "Save")

    /// "Saved 3 items in Mobile App." with what was kept.
    static func saved(_ result: FolderSaveResultModel, folderName: String) -> String {
        let changed = result.items.added + result.items.replaced
        var text = String(inflected: AttributedString(
            localized: "folder.destination.saved",
            defaultValue: "Saved ^[\(changed) item](inflect: true) in \(folderName)."
        ))
        if result.items.kept > 0 {
            text += " " + String(localized: "folder.destination.kept", defaultValue: "Kept \(result.items.kept) that the folder already had.")
        }
        return text
    }
}

/// Texts of receiving a copy of a folder.
enum FolderShareCopy {
    static let alreadyImported = String(
        localized: "folder.share.alreadyImported",
        defaultValue: "You already saved or imported this copy once. Saving it again changes nothing unless you replace values."
    )
}
