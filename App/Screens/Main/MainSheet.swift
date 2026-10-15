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
    case nearbySend(NearbySendContext)
    case nearbyReceive(NearbyReceiveContext)

    // Main/ (owned by the main window)
    /// "Add repository by name…" for one account (§10 Column 1).
    case addRepositoryByName(AddRepositoryContext)

    var id: Self {
        self
    }
}

// MARK: - Contexts

/// What ``ItemEditorScreen`` edits. `scope` is where the item is (or will be) and `kind` the
/// table the user was looking at.
struct ItemEditorContext: Hashable {
    enum Mode: Hashable {
        /// A new item in ``ItemEditorContext/scope`` (kind preselected, still changeable).
        case add(ConfigKind)
        /// Rename and/or replace the value (`ConfigRepository.renameItem` / `editValue`).
        case edit(ConfigItemID)
        /// Fill a value-missing secret, with the "push on next sync" choice (§7.8).
        case fill(ConfigItemID)
        /// "Convert/Move…" (D11): pick another kind and/or scope (`ConfigRepository.moveItem`).
        case move(ConfigItemID)
    }

    let repositoryID: RepoID
    let scope: ConfigScope
    let mode: Mode
}

/// "+ New Environment" in the scopes column.
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

/// Import .env (⇧⌘I) into the selected scope.
struct EnvImportContext: Hashable {
    let repositoryID: RepoID
    let scope: ConfigScope
    /// A file chosen before the sheet opened (drag and drop); nil lets the sheet offer a file
    /// picker or paste.
    let fileURL: URL?
}

/// Export .env… of one scope.
struct EnvExportContext: Hashable {
    let repositoryID: RepoID
    let scope: ConfigScope
}

/// Share › File… (`.fxvault` export).
struct ShareExportContext: Hashable {
    let selection: ShareSelectionModel
}

/// A `.fxvault` file to import (opened from Finder or AirDrop, or chosen in the sheet).
struct ShareImportContext: Hashable {
    let fileURL: URL
}

/// Share › Nearby… (send).
struct NearbySendContext: Hashable {
    /// The current selection; nil lets the sheet ask what to send.
    let selection: ShareSelectionModel?
}

/// Share › Receive Nearby….
struct NearbyReceiveContext: Hashable {}

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
