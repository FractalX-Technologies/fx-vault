import AppKit
import Foundation
import GitHubKit
import SharingKit
import VaultCore
import VaultCrypto
import VaultData

/// Composition root: builds the managers and repositories that view models depend on.
///
/// - `live`: the real vault under `~/Library/Application Support`, the keychain and gh.
/// - `preview`: in-memory and side-effect free: an in-memory database, fake Touch ID, a private
///   pasteboard, in-memory preferences, inert lock sources and a scripted gh
///   (``VaultDataComponents/makeOffline(session:runner:clock:sandbox:)``). SwiftUI previews use
///   it, and so does the app while it hosts the test bundle (nothing under `~/Library`, no shell
///   probe, no gh).
/// - `test`: unit tests pass their own fakes to ``init(mode:vaultManager:data:preferences:clipboard:autoLock:ghStatusProbe:dockBadge:passphraseGenerator:vaultDirectory:clock:connectivity:loginItem:)``.
///
/// Order matters: the session first, then the repositories (``data``), then `VaultManager`,
/// whose `onLock` purges the token cache of ``VaultDataComponents/github`` (§5.8 Phase A).
final class AppContainer {
    enum Mode: Equatable {
        case live
        case preview
        case test
        #if FXVAULT_UI_TESTING
        /// The UITesting build's only mode: a throwaway vault under `root` and a scripted gh
        /// (``AppContainer/uiTest(root:)``).
        case uiTest(root: URL)
        #endif

        /// Set by XCTest in the host app's environment while it runs the test bundle.
        static let xcTestConfigurationKey = "XCTestConfigurationFilePath"

        /// The mode for this process: `preview` while hosting tests, otherwise `live`.
        static func forCurrentProcess(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Mode {
            if environment[xcTestConfigurationKey] != nil {
                return .preview
            }
            #if FXVAULT_UI_TESTING
            // Never `live`: the UITesting build shares the Debug vault folder's flavor, so falling
            // back would open the developer's FX Vault Dev vault.
            return .uiTest(root: UITestLaunch.prepareRoot())
            #else
            return .live
            #endif
        }
    }

    let mode: Mode
    let vaultManager: VaultManager
    /// Every VaultData repository (one instance each for the process).
    let data: VaultDataComponents
    /// Re-authentication before exports and shares (D30).
    let reauth: ReauthGate
    let preferences: PreferencesManager
    let clipboard: ClipboardManager
    let autoLock: AutoLockManager
    let ghStatusProbe: any GHStatusProbing
    let dockBadge: any DockBadgeDisplaying
    /// Generates 6-word passphrases; nil if the bundled wordlist failed its integrity check.
    let passphraseGenerator: PassphraseGenerator?
    /// The vault folder for Preferences › Advanced › Reveal; nil for in-memory vaults.
    let vaultDirectory: URL?
    /// The clock every timer of the UI uses (reveal re-mask, clipboard clear).
    let clock: any VaultClock
    /// Internet reachability (`NWPathMonitor` live; a fixed online path in previews and tests
    /// unless they pass their own). `AppViewModel` starts it.
    let connectivity: ConnectivityMonitor
    /// Whether GitHub answers the gh calls the app makes (fed by the view models).
    let gitHubReachability = GitHubReachability()
    /// A Key Vault's subscription found after its Refresh (1.0 D6c6), with the session's misses.
    let keyVaultSubscriptions: KeyVaultSubscriptionLookup
    /// Open at login: `SMAppService` live, recorded everywhere else (never registers a test host).
    let loginItem: any LoginItemControlling

    init(
        mode: Mode,
        vaultManager: VaultManager,
        data: VaultDataComponents,
        preferences: PreferencesManager,
        clipboard: ClipboardManager,
        autoLock: AutoLockManager,
        ghStatusProbe: any GHStatusProbing,
        dockBadge: any DockBadgeDisplaying,
        passphraseGenerator: PassphraseGenerator?,
        vaultDirectory: URL?,
        clock: any VaultClock,
        connectivity: ConnectivityMonitor? = nil,
        loginItem: (any LoginItemControlling)? = nil
    ) {
        self.mode = mode
        self.vaultManager = vaultManager
        self.data = data
        reauth = ReauthGate(manager: vaultManager)
        keyVaultSubscriptions = KeyVaultSubscriptionLookup(discovery: data.azureDiscovery, destinations: data.destinations)
        self.preferences = preferences
        self.clipboard = clipboard
        self.autoLock = autoLock
        self.ghStatusProbe = ghStatusProbe
        self.dockBadge = dockBadge
        self.passphraseGenerator = passphraseGenerator
        self.vaultDirectory = vaultDirectory
        self.clock = clock
        self.connectivity = connectivity ?? ConnectivityMonitor(source: FixedNetworkPathSource(), clock: clock)
        self.loginItem = loginItem ?? RecordedLoginItem()
    }

    /// Whether this container behaves as the running app: the real vault, keychain and gh, or
    /// the UI-testing host, whose gh is scripted but whose window must activate like the app's.
    var hasSideEffects: Bool {
        switch mode {
        case .live: true
        case .preview, .test: false
        #if FXVAULT_UI_TESTING
        case .uiTest: true
        #endif
        }
    }

    // MARK: - Factories

    /// The container for `mode`.
    static func make(mode: Mode) throws -> AppContainer {
        switch mode {
        case .live: try live()
        case .preview, .test: try preview()
        #if FXVAULT_UI_TESTING
        case .uiTest(let root): try uiTest(root: root)
        #endif
        }
    }

    /// The real vault, keychain, pasteboard, gh and system lock signals.
    static func live() throws -> AppContainer {
        let session = try VaultSession.openLive()
        let capabilities = BuildCapabilities()
        let clock = SystemClock()
        let data = VaultDataComponents.make(
            session: session,
            runner: ProcessRunner(clock: clock),
            identity: .current(),
            workingDirectory: try EmptyWorkingDirectory.prepareDefault(),
            clock: clock
        )
        let github = data.github
        let vaultManager = try VaultManager(
            session: session,
            policy: .production,
            biometricStore: KeychainManager(
                accessGroup: capabilities.keychainAccessGroup,
                authManager: BiometricAuthManager()
            ),
            capabilities: capabilities,
            clock: clock,
            onLock: { github.purgeTokens() }
        )
        let preferences = PreferencesManager(store: UserDefaultsPreferencesStore())
        return AppContainer(
            mode: .live,
            vaultManager: vaultManager,
            data: data,
            preferences: preferences,
            clipboard: ClipboardManager(pasteboard: .general, clock: clock),
            autoLock: AutoLockManager(
                clock: clock,
                idleSource: LocalEventIdleSource(),
                signalSource: SystemLockSignalSource(),
                ticker: DispatchInactivityTicker(),
                timeout: { preferences.autoLockTimeout }
            ),
            ghStatusProbe: GitHubEnvironmentStatusProbe(github: github, preferences: preferences),
            dockBadge: DockBadgeManager(),
            passphraseGenerator: try? PassphraseGenerator.bundled(),
            vaultDirectory: session.databaseDirectory,
            clock: clock,
            connectivity: ConnectivityMonitor(source: NWPathMonitorSource(), clock: clock),
            loginItem: LoginItemManager()
        )
    }

    /// An in-memory vault with fakes (SwiftUI previews and the test host).
    static func preview(
        capabilities: FakeBuildCapabilities = FakeBuildCapabilities(),
        ghStatus: GHStatusModel = .ready(version: Limits.minimumGHVersion, path: previewGHPath)
    ) throws -> AppContainer {
        let clock = SystemClock()
        let session = try VaultSession.inMemory()
        return try sandboxed(
            mode: .preview,
            session: session,
            data: VaultDataComponents.makeOffline(session: session, clock: clock),
            capabilities: capabilities,
            preferences: PreferencesManager(store: InMemoryPreferencesStore()),
            ghStatusProbe: { _ in FixedGHStatusProbe(ghStatus) },
            clock: clock
        )
    }

    /// The fakes every container but `live` shares: fake Touch ID, the testing KDF policy, a
    /// private pasteboard, inert lock sources and a recorded Dock badge.
    static func sandboxed(
        mode: Mode,
        session: VaultSession,
        data: VaultDataComponents,
        capabilities: FakeBuildCapabilities,
        preferences: PreferencesManager,
        ghStatusProbe: (VaultDataComponents) -> any GHStatusProbing,
        clock: any VaultClock
    ) throws -> AppContainer {
        let github = data.github
        let vaultManager = try VaultManager(
            session: session,
            policy: .testing,
            biometricStore: FakeBiometricKeyStore(),
            capabilities: capabilities,
            clock: clock,
            onLock: { github.purgeTokens() }
        )
        let inert = InertLockSources()
        return AppContainer(
            mode: mode,
            vaultManager: vaultManager,
            data: data,
            preferences: preferences,
            clipboard: ClipboardManager(pasteboard: NSPasteboard(name: previewPasteboardName), clock: clock),
            autoLock: AutoLockManager(
                clock: clock,
                idleSource: inert,
                signalSource: inert,
                ticker: inert,
                timeout: { preferences.autoLockTimeout }
            ),
            ghStatusProbe: ghStatusProbe(data),
            dockBadge: RecordedDockBadge(),
            passphraseGenerator: try? PassphraseGenerator.bundled(),
            vaultDirectory: session.databaseDirectory,
            clock: clock
        )
    }

    /// A private pasteboard, so previews and the test host never touch the user's clipboard.
    static let previewPasteboardName = NSPasteboard.Name("io.fractalx.fxvault.preview")
    /// The gh path shown in previews.
    static let previewGHPath = "/opt/homebrew/bin/gh"
    /// The uid of the other administrator in the "owned by another user" preview.
    static let previewOtherOwnerUID: UInt32 = 502
}

/// The result of building the app's dependencies at launch.
enum AppBootstrap {
    case ready(AppViewModel)
    /// The vault database could not be opened (permissions, corruption, disk full). The app shows
    /// ``StartupFailureScreen``; it never falls back to an empty vault.
    case failed(ErrorPresentationModel)

    var viewModel: AppViewModel? {
        if case .ready(let viewModel) = self { viewModel } else { nil }
    }

    static func forCurrentProcess(mode: AppContainer.Mode = .forCurrentProcess()) -> AppBootstrap {
        do {
            return .ready(AppViewModel(container: try AppContainer.make(mode: mode)))
        } catch {
            AppLog.vault.error("Vault database could not be opened")
            return .failed(error.presentation)
        }
    }
}
