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
/// - `.env` export needs `reauth.authorizeEnvExport(with:session:)`; `.fxvault` export and nearby
///   send need `reauth.authorizeShare(_:with:session:)`, with ``reauthPrompt(for:)`` for Touch ID.
struct FeatureDependencies {
    let session: VaultSession
    let config: ConfigRepository
    let catalog: RepoCatalogRepository
    let github: GitHubEnvironmentRepository
    let sync: SyncRepository
    let drift: DriftRepository
    let envFiles: EnvFileRepository
    let sharing: SharingRepository
    /// Staging, owners, templates and name checks. Clone through ``cloner``.
    let creation: RepoCreationRepository
    let cloner: any RepoCloning
    let reauth: ReauthGate
    let clipboard: ClipboardManager
    let preferences: PreferencesManager
    let passphraseGenerator: PassphraseGenerator?
    let clock: any VaultClock
    let actions: MainActions
    /// The vault's Touch ID status, read without a prompt; nil when it cannot be read. Sheets
    /// that re-authenticate offer "Use Touch ID" only when it is `.available`.
    let touchIDStatus: () -> BiometricUnlockStatus?

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
        creation = data.creation
        cloner = data.cloner
        reauth = container.reauth
        clipboard = container.clipboard
        preferences = container.preferences
        passphraseGenerator = container.passphraseGenerator
        clock = container.clock
        self.actions = actions
        let vaultManager = container.vaultManager
        touchIDStatus = { try? vaultManager.biometricUnlockStatus() }
    }

    /// Decrypts the item's value, copies it with the clipboard privacy markers (cleared after
    /// 30 s, on lock and on quit) and wipes the decrypted bytes.
    ///
    /// - Throws: `.valueMissing`, `.itemNotFound`, `.vault(.locked)`, `.unexpected` for bytes
    ///   that are not UTF-8 (never stored by FX Vault).
    func copyValue(of id: ConfigItemID) throws(ConfigRepositoryError) {
        let value = try config.reveal(id)
        defer { value.wipe() }
        guard let text = value.utf8String() else { throw .unexpected }
        clipboard.copy(text)
    }

    /// The Touch ID prompt for a re-authentication (D24: texts are built in the app).
    static func reauthPrompt(for purpose: ReauthPurpose) -> BiometricPrompt {
        let fallback = String(localized: "touchID.prompt.fallback", defaultValue: "Use Master Password")
        let reason = switch purpose {
        case .export:
            String(localized: "touchID.prompt.export", defaultValue: "export a .env file")
        case .share:
            String(localized: "touchID.prompt.share", defaultValue: "share configuration")
        case .nearbySend:
            String(localized: "touchID.prompt.nearbySend", defaultValue: "send configuration to a nearby Mac")
        }
        return BiometricPrompt(reason: reason, fallbackTitle: fallback)
    }

    /// Dependencies over a fresh preview container with inert actions (SwiftUI previews only).
    static func preview() throws -> FeatureDependencies {
        FeatureDependencies(container: try AppContainer.preview(), actions: .inert)
    }
}
