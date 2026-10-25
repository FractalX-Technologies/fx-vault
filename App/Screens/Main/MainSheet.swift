import Foundation
import VaultCore
import VaultData

/// Every sheet the main window presents (§10 Sheets): the router of the UI feature contract
/// (ARCHITECTURE.md "UI feature contract").
///
/// ``MainViewModel/activeSheet`` holds at most one route; `MainScreen` maps each case to the
/// feature's entry view, built as `EntryView(context: <Context>, dependencies:
/// FeatureDependencies)`. Contexts are plain values (ids, never values or names that could go
/// stale), so a feature re-reads what it needs through its repository.
enum MainSheet: Hashable, Identifiable {
    // ItemEditor/
    /// Add, edit, fill or convert/move one secret or variable.
    case itemEditor(ItemEditorContext)

    // Main/Organization/ (1.0)
    /// Add or edit an organization secret or variable, with who can use it.
    case orgItemEditor(OrgItemEditorContext)

    // CopyToRepository/
    /// Copy To › Another Repository… (v0.4.1): linked copies into any repository of the vault.
    case copyToRepository(CopyToRepositoryContext)

    // Environment/
    case newEnvironment(NewEnvironmentContext)
    /// Name and deployment branch policy (`BranchPolicyEditor`).
    case environmentSettings(EnvironmentContext)
    case renameEnvironment(EnvironmentContext)
    case duplicateEnvironment(EnvironmentContext)

    // Sync/ and Drift/
    case sync(SyncContext)
    case driftReview(DriftReviewContext)

    // CreateRepo/
    case createRepository(CreateRepoContext)

    // EnvFile/
    case envImport(EnvImportContext)
    case envExport(EnvExportContext)

    // Sharing/
    case shareExport(ShareExportContext)
    case shareImport(ShareImportContext)

    // Folders/ (v0.7.0)
    /// New Folder… (optionally with items to copy in) and Rename….
    case folderName(FolderNameContext)

    // Main/Destination/ (v0.8.0)
    /// "+ Add Destination" for a repository.
    case addDestination(AddDestinationContext)
    /// A destination's Settings…: its stage.
    case destinationSettings(DestinationSettingsContext)
    /// Refresh's findings for one destination: Keep Mine or Use Remote.
    case destinationDrift(DestinationDriftContext)

    // Main/ (owned by the main window)
    /// "Add repository by name…" for one account (§10 Column 1).
    case addRepositoryByName(AddRepositoryContext)

    var id: Self {
        self
    }

    /// Routes that cannot do anything without GitHub; the router refuses them while offline
    /// (v0.2.0).
    var needsInternet: Bool {
        switch self {
        case .sync, .createRepository, .addRepositoryByName, .addDestination, .destinationDrift:
            true
        default:
            false
        }
    }
}

// MARK: - Contexts

/// "+ Add Destination" (v0.8.0).
struct AddDestinationContext: Hashable {
    let repositoryID: RepoID
}

/// A destination's Settings… (v0.8.0).
struct DestinationSettingsContext: Hashable {
    let destinationID: DestinationID
}

/// Refresh's findings for one destination (v0.8.0).
struct DestinationDriftContext: Hashable {
    let destinationID: DestinationID
    let findings: [DestinationDriftModel]
}

/// What ``CopyToRepositoryScreen`` copies (v0.4.1): items of one scope, by id.
struct CopyToRepositoryContext: Hashable {
    let itemIDs: [ConfigItemID]
    /// The scope or folder (v0.7.0) the items are in.
    let source: ItemPlaceModel

    init(itemIDs: [ConfigItemID], source: ItemPlaceModel) {
        self.itemIDs = itemIDs
        self.source = source
    }

    init(itemIDs: [ConfigItemID], sourceRepositoryID: RepoID, sourceScope: ConfigScope) {
        self.init(itemIDs: itemIDs, source: .scope(repositoryID: sourceRepositoryID, scope: sourceScope))
    }
}

/// What ``OrgItemEditorScreen`` adds or edits (1.0).
struct OrgItemEditorContext: Hashable {
    enum Mode: Hashable {
        /// A new item; the kind is preselected and still changeable.
        case add(ConfigKind)
        /// A new value and/or access; names never change (a rename is a delete and an add).
        case edit(ConfigItemID)
    }

    let organizationID: OrganizationID
    let mode: Mode
    /// The organization's repositories the sidebar lists, offered for Selected access. Only
    /// names to pick from: GitHub checks them on Sync.
    let repositoryCandidates: [String]
}

/// What ``ItemEditorScreen`` edits. `scope` is where the item is (or will be) and `kind` the
/// table the user was looking at.
struct ItemEditorContext: Hashable {
    enum Mode: Hashable {
        /// A new item in ``ItemEditorContext/scope`` (kind preselected, still changeable).
        case add(ConfigKind)
        /// Rename and/or replace the value (`ConfigRepository.renameItem` / `editValue`).
        case edit(ConfigItemID)
        /// Fill a value-missing secret: pushed on the next Sync unless it already matches GitHub
        /// (§7.8, v0.1.2).
        case fill(ConfigItemID)
        /// "Convert/Move…" (D11): pick another kind and/or scope (`ConfigRepository.moveItem`).
        case move(ConfigItemID)
    }

    /// A scope of a repository, or a folder (v0.7.0: add and edit only).
    let place: ItemPlaceModel
    let mode: Mode
    /// Fill: start with "Already matches GitHub (don't push)" checked. Only the drift review
    /// sets it, after "Accept GitHub" (the user chose GitHub's value).
    var fillMatchesGitHub = false

    init(repositoryID: RepoID, scope: ConfigScope, mode: Mode, fillMatchesGitHub: Bool = false) {
        place = .scope(repositoryID: repositoryID, scope: scope)
        self.mode = mode
        self.fillMatchesGitHub = fillMatchesGitHub
    }

    /// Add or edit an item of a folder.
    init(folderID: FolderID, mode: Mode) {
        place = .folder(folderID)
        self.mode = mode
    }

    /// Add, edit or fill an item of a destination (v0.8.0).
    init(destinationID: DestinationID, mode: Mode, fillMatchesGitHub: Bool = false) {
        place = .destination(destinationID)
        self.mode = mode
        self.fillMatchesGitHub = fillMatchesGitHub
    }
}

/// New Folder… or Rename… (v0.7.0).
struct FolderNameContext: Hashable {
    enum Mode: Hashable {
        /// A new folder; `itemIDs` are copied into it (rows dropped on "New Folder").
        case create(itemIDs: [ConfigItemID])
        case rename(FolderID)
    }

    let mode: Mode
}

/// "+ New Environment" under the selected repository in the sidebar.
struct NewEnvironmentContext: Hashable {
    let repositoryID: RepoID
}

/// One existing environment (settings, rename, duplicate).
struct EnvironmentContext: Hashable {
    let repositoryID: RepoID
    let environmentID: EnvironmentID
}

/// The Sync sheet (Summary → Deletions → Progress → Result, §10).
struct SyncContext: Hashable {
    /// The repositories to sync; nil syncs every repository with pending changes (toolbar Sync).
    let repositoryIDs: Set<RepoID>?
}

/// The drift review of one repository (§7.7).
struct DriftReviewContext: Hashable {
    let repositoryID: RepoID
}

/// New Repository (⌘N). Both values only preselect the owner picker.
struct CreateRepoContext: Hashable {
    /// The account selected in the sidebar, if any.
    let accountLogin: String?
    /// The owner group selected in the sidebar (the account or an organization), if any.
    let ownerLogin: String?
}

/// Import .env (⇧⌘I, the toolbar, or the detail table's Add menu and ⌘V) into a scope.
struct EnvImportContext: Hashable {
    /// How the sheet opens.
    enum Start: Hashable {
        /// The file chooser, with Paste one click away (toolbar Import .env, "Import .env File…").
        case chooser
        /// The paste editor, focused and empty ("Paste Multiple…").
        case pasteEditor
        /// The paste editor prefilled with text the user pasted (⌘V on the detail table). The
        /// sheet takes the text out of the buffer once.
        case pasted(EnvPasteBuffer)
    }

    /// The scope the sheet preselects (the scope that is open; still changeable), or a folder
    /// (v0.7.0), the only target then.
    let place: ItemPlaceModel
    /// A file chosen before the sheet opened (drag and drop); nil lets the sheet offer a file
    /// picker or paste.
    let fileURL: URL?
    /// The kind every row starts as (the detail table's tab); nil keeps `CredentialClassifier`'s
    /// suggestion per row (toolbar Import .env).
    let defaultKind: ConfigKind?
    let start: Start

    init(
        repositoryID: RepoID,
        scope: ConfigScope,
        fileURL: URL? = nil,
        defaultKind: ConfigKind? = nil,
        start: Start = .chooser
    ) {
        self.init(place: .scope(repositoryID: repositoryID, scope: scope), fileURL: fileURL, defaultKind: defaultKind, start: start)
    }

    init(place: ItemPlaceModel, fileURL: URL? = nil, defaultKind: ConfigKind? = nil, start: Start = .chooser) {
        self.place = place
        self.fileURL = fileURL
        self.defaultKind = defaultKind
        self.start = start
    }
}

/// Text the user pasted on the detail table, handed to the import sheet without putting the value
/// in the router's state: contexts compare and hash the buffer by identity, and its description
/// never shows the text. ``take()`` hands the bytes over once; bytes never taken are wiped by
/// `SecretBytes` when the buffer goes away.
final class EnvPasteBuffer: Hashable, CustomStringConvertible {
    private var contents: SecretBytes?

    init(_ contents: SecretBytes) {
        self.contents = contents
    }

    /// The pasted bytes, once (the caller wipes them); nil afterwards.
    func take() -> SecretBytes? {
        defer { contents = nil }
        return contents
    }

    /// True until ``take()`` handed the bytes over.
    var hasContents: Bool {
        contents != nil
    }

    var description: String {
        "EnvPasteBuffer(<redacted>)"
    }

    static func == (lhs: EnvPasteBuffer, rhs: EnvPasteBuffer) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// Export .env… of one scope or (v0.7.0) one folder.
struct EnvExportContext: Hashable {
    let place: ItemPlaceModel

    init(repositoryID: RepoID, scope: ConfigScope) {
        place = .scope(repositoryID: repositoryID, scope: scope)
    }

    init(folderID: FolderID) {
        place = .folder(folderID)
    }

    init(destinationID: DestinationID) {
        place = .destination(destinationID)
    }
}

/// Share › File… (`.fxvault` export; the project share sheet since v0.9.0).
struct ShareExportContext: Hashable {
    let selection: ShareSelectionModel
}

/// A `.fxvault` file to import (opened from Finder or AirDrop, or chosen in the sheet).
struct ShareImportContext: Hashable {
    let fileURL: URL
}

/// "Add repository by name…" for one account.
struct AddRepositoryContext: Hashable {
    let accountLogin: String
}

/// What a feature asks the main window to reload after it changed something the database
/// observation does not cover (gh-backed data). Local vault edits refresh by themselves: every
/// column observes `ConfigRepository` streams.
enum MainRefreshRequest: Hashable {
    /// Re-list accounts and repositories (sidebar), for example after a repository was created.
    case catalog
    /// Re-read one repository's metadata from GitHub (`RepoCatalogRepository.refreshRepository`).
    case repository(RepoID)
    /// Run the drift check of one repository again (`DriftRepository.refresh`).
    case drift(RepoID)
}
