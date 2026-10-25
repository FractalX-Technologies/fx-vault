import Foundation
import SharingKit
import VaultCore
import VaultData

/// What the main window lets a feature do besides calling repositories (UI feature contract).
struct MainActions {
    /// Presents another main-window sheet in place of the current one (for example drift review
    /// → item editor in fill mode).
    let present: (MainSheet) -> Void
    /// Reloads gh-backed data the database observation does not cover.
    let refresh: (MainRefreshRequest) -> Void
    /// Starts a ``SyncActivity`` (auto-lock inactivity suspended, Sync button shows progress).
    /// The caller ends it when the run is over.
    let beginSyncActivity: () -> SyncActivity
    /// Registers a lock observer (held weakly), for view models that hold typed passwords or
    /// decrypted values outside SwiftUI state.
    let addLockObserver: (any LockObserving) -> Void
    /// True when gh is detected with an account (sync, drift, import and create need it).
    let isGitHubReady: () -> Bool
    /// Selects a vault repository in the sidebar (for example the one New Repository staged).
    /// A repository the vault observation has not delivered yet is selected when it appears.
    let select: (RepoID) -> Void
    /// Selects a vault repository and one of its scopes (a linked copy's place, v0.4.1).
    var open: (RepoID, ConfigScope) -> Void = { _, _ in }
    /// Selects a folder in the sidebar (a linked copy's place, v0.7.0).
    var openFolder: (FolderID) -> Void = { _ in }
    /// Selects a repository and one of its destinations (a linked copy's place, v0.8.0).
    var openDestination: (DestinationID) -> Void = { _ in }
    /// Selects a repository's Overview at a stage (nil: the Overview's default), after a project
    /// share import (v0.9.0).
    var openOverview: (RepoID, String?) -> Void = { _, _ in }

    /// Shows a scope of a repository, a folder or a destination.
    func openPlace(_ place: ItemPlaceModel) {
        switch place {
        case .scope(let repositoryID, let scope): open(repositoryID, scope)
        case .folder(let id): openFolder(id)
        case .destination(let id): openDestination(id)
        }
    }

    /// Actions that do nothing (SwiftUI previews).
    static let inert = MainActions(
        present: { _ in },
        refresh: { _ in },
        beginSyncActivity: { SyncActivity.untracked() },
        addLockObserver: { _ in },
        isGitHubReady: { false },
        select: { _ in }
    )
}

/// The single dependency mechanism of every feature entry view (ARCHITECTURE.md "UI feature
/// contract"): each entry view is `init(context: <Context>, dependencies: FeatureDependencies)`
/// and builds its `@Observable` view model from these values. Nothing else (no environment
/// values, no singletons) carries dependencies into a feature.
///
/// Rules:
/// - Values are decrypted only through ``config`` (`reveal`) or the feature's repository, and
///   copied only through ``copyValue(of:)`` / ``clipboard`` (§5.9).
/// - Value entry uses `SecretValueEditor` (§5.11).
/// - `.env` export needs `reauth.authorizeEnvExport(with:session:)`; `.fxvault` export
///   needs `reauth.authorizeShare(_:with:session:)`, with ``reauthPrompt(for:)`` for Touch ID.
struct FeatureDependencies {
    let session: VaultSession
    let config: ConfigRepository
    let catalog: RepoCatalogRepository
    let github: GitHubEnvironmentRepository
    let sync: SyncRepository
    let drift: DriftRepository
    let envFiles: EnvFileRepository
    let sharing: SharingRepository
    /// Folders of secrets and variables (v0.7.0).
    let folders: FolderRepository
    /// Runtime destinations and provider connections (v0.8.0).
    let destinations: DestinationRepository
    /// The stage Overview and `fxvault.yml` (v0.8.0).
    let overview: StageOverviewRepository
    /// Destination Sync, Refresh and import (v0.8.0).
    let destinationSync: DestinationSyncRepository
    /// Token checks and the Add Destination pickers (v0.8.0).
    let destinationAccess: DestinationAccessRepository
    /// Staging, owners, templates and name checks. Clone through ``cloner``.
    let creation: RepoCreationRepository
    let cloner: any RepoCloning
    let reauth: ReauthGate
    let clipboard: ClipboardManager
    let preferences: PreferencesManager
    let passphraseGenerator: PassphraseGenerator?
    let clock: any VaultClock
    /// Internet reachability. While offline, gh-backed actions are disabled with
    /// `ConnectivityCopy.offlineHelp`; sharing a file does not depend on it.
    let connectivity: ConnectivityMonitor
    /// Report the outcome of gh-backed calls here (`record(error)` / `recordSuccess()`), which
    /// drives the "GitHub isn't responding" banner.
    let gitHubReachability: GitHubReachability
    let actions: MainActions
    /// The vault's Touch ID status, read without a prompt; nil when it cannot be read. Sheets
    /// that re-authenticate offer "Use Touch ID" only when it is `.available`.
    let touchIDStatus: () -> BiometricUnlockStatus?

    /// Whether a share import preview reads GitHub's listing: only when gh is ready and the Mac
    /// is online. Otherwise it plans without it at once (each attempt would retry and time out
    /// first).
    var checksGitHub: Bool {
        actions.isGitHubReady() && connectivity.isOnline
    }

    init(container: AppContainer, actions: MainActions) {
        let data = container.data
        session = data.session
        config = data.config
        catalog = data.catalog
        github = data.github
        sync = data.sync
        drift = data.drift
        envFiles = data.envFiles
        sharing = data.sharing
        folders = data.folders
        destinations = data.destinations
        overview = data.overview
        destinationSync = data.destinationSync
        destinationAccess = data.destinationAccess
        creation = data.creation
        cloner = data.cloner
        reauth = container.reauth
        clipboard = container.clipboard
        preferences = container.preferences
        passphraseGenerator = container.passphraseGenerator
        clock = container.clock
        connectivity = container.connectivity
        gitHubReachability = container.gitHubReachability
        self.actions = actions
        let vaultManager = container.vaultManager
        touchIDStatus = { try? vaultManager.biometricUnlockStatus() }
    }

    /// Decrypts the item's value (a repository or folder item), copies it with the clipboard
    /// privacy markers (cleared after 30 s, on lock and on quit) and wipes the decrypted bytes.
    ///
    /// - Throws: `.valueMissing`, `.itemNotFound`, `.vault(.locked)`, `.unexpected` for bytes
    ///   that are not UTF-8 (never stored by FX Vault).
    func copyValue(of id: ConfigItemID) throws(ConfigRepositoryError) {
        let value = try config.reveal(id)
        defer { value.wipe() }
        guard let text = value.utf8String() else { throw .unexpected }
        clipboard.copy(text)
    }

    /// The names among `ids` that `place` (a repository scope, a folder or, v0.8.0, a
    /// destination) already holds: the copy asks whether to replace or keep them.
    func copyConflicts(_ ids: [ConfigItemID], to place: ItemPlaceModel) throws(ConfigRepositoryError) -> [String] {
        switch place {
        case .scope(let repositoryID, let scope): try config.copyConflicts(ids, to: scope, repositoryID: repositoryID)
        case .folder(let folderID): try folders.copyConflicts(ids, to: folderID)
        case .destination(let destinationID): try destinations.copyConflicts(ids, to: destinationID)
        }
    }

    /// Copies items into a repository scope (pending for Sync) or a folder (at once), each copy
    /// linked to its source.
    func copyItems(
        _ ids: [ConfigItemID],
        to place: ItemPlaceModel,
        conflicts: ItemCopyConflictPolicy
    ) throws(ConfigRepositoryError) -> ItemCopyResultModel {
        switch place {
        case .scope(let repositoryID, let scope):
            try config.copyItems(ids, to: scope, repositoryID: repositoryID, conflicts: conflicts)
        case .folder(let folderID):
            try folders.copyItems(ids, to: folderID, conflicts: conflicts)
        case .destination(let destinationID):
            try destinations.copyItems(ids, to: destinationID, conflicts: conflicts)
        }
    }

    /// Copy To › Destination targets (v0.8.0): the destinations of `repositoryID` but `excluded`.
    func destinationCopyTargets(repositoryID: RepoID, excluding excluded: DestinationID? = nil) -> [ItemCopyTargetModel] {
        ((try? destinations.destinations(repositoryID: repositoryID)) ?? [])
            .filter { $0.id != excluded }
            .map { ItemCopyTargetModel(place: .destination($0.id), title: $0.copyTargetTitle, isEditable: true) }
    }

    /// Copy To › Folder targets (v0.7.0): every folder but `excluded`, by sidebar order.
    func folderCopyTargets(excluding excluded: FolderID? = nil) -> [ItemCopyTargetModel] {
        ((try? folders.folders()) ?? [])
            .filter { $0.id != excluded }
            .map { ItemCopyTargetModel(place: .folder($0.id), title: $0.name, isEditable: true) }
    }

    /// The Touch ID prompt for a re-authentication (D24: texts are built in the app).
    static func reauthPrompt(for purpose: ReauthPurpose) -> BiometricPrompt {
        let fallback = String(localized: "touchID.prompt.fallback", defaultValue: "Use Master Password")
        let reason = switch purpose {
        case .export:
            String(localized: "touchID.prompt.export", defaultValue: "export a .env file")
        case .share:
            String(localized: "touchID.prompt.share", defaultValue: "share configuration")
        }
        return BiometricPrompt(reason: reason, fallbackTitle: fallback)
    }

    /// Dependencies over a fresh preview container with inert actions (SwiftUI previews only).
    static func preview() throws -> FeatureDependencies {
        FeatureDependencies(container: try AppContainer.preview(), actions: .inert)
    }
}
