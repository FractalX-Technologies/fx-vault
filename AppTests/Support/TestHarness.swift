import AppKit
import Foundation
import GitHubKit
import SharingKit
import VaultCore
import VaultCrypto
import VaultData
@testable import FXVault

/// A strong test password (well above 12 characters and 60 estimated bits).
let testPassword = "Tq9#vL2!mZ7@xR4$kW8"
/// A second strong test password.
let otherTestPassword = "Hn5^pD3&cY6*sB1%gJ0"

/// An idle source the test drives by hand.
@MainActor
final class FakeIdleSource: IdleEventSource {
    private var onInteraction: (@MainActor () -> Void)?
    private(set) var isStarted = false

    func start(onInteraction: @escaping @MainActor () -> Void) {
        self.onInteraction = onInteraction
        isStarted = true
    }

    func stop() {
        onInteraction = nil
        isStarted = false
    }

    func interact() {
        onInteraction?()
    }
}

/// A lock signal source the test drives by hand.
@MainActor
final class FakeLockSignalSource: LockSignalSource {
    private var onSignal: (@MainActor (LockTrigger) -> Void)?

    func start(onSignal: @escaping @MainActor (LockTrigger) -> Void) {
        self.onSignal = onSignal
    }

    func stop() {
        onSignal = nil
    }

    func send(_ trigger: LockTrigger) {
        onSignal?(trigger)
    }
}

/// A ticker the test fires by hand.
@MainActor
final class FakeTicker: InactivityTicker {
    private var onTick: (@MainActor () -> Void)?
    private(set) var interval: Duration?

    func start(interval: Duration, onTick: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.onTick = onTick
    }

    func stop() {
        onTick = nil
    }

    func tick() {
        onTick?()
    }
}

/// A network path source the test drives by hand (connectivity banner, v0.2.0).
@MainActor
final class FakeNetworkPathSource: NetworkPathSource {
    private var onUpdate: (@MainActor (NetworkPathModel) -> Void)?
    private(set) var isStarted = false

    func start(onUpdate: @escaping @MainActor (NetworkPathModel) -> Void) {
        self.onUpdate = onUpdate
        isStarted = true
    }

    func stop() {
        onUpdate = nil
        isStarted = false
    }

    func send(_ path: NetworkPathModel) {
        onUpdate?(path)
    }
}

/// The starting state of a harness vault.
enum TestVaultState {
    case none
    case locked
    case unlocked
}

/// An `AppViewModel` over an in-memory vault, fake Touch ID, a manual clock, a private
/// pasteboard, in-memory preferences, hand-driven lock sources and a scripted gh
/// (`FakeCommandRunner` plus an optional fake gh file in a temporary folder). No test touches the
/// real vault, keychain, clipboard, gh or `~/Library`.
@MainActor
final class TestHarness {
    let app: AppViewModel
    let container: AppContainer
    let clock: ManualClock
    let biometrics: FakeBiometricKeyStore
    let capabilities: FakeBuildCapabilities
    /// Scripted gh, git and ssh.
    let runner = FakeCommandRunner()
    /// A per-harness temporary folder (fake gh, offline home); removed in `deinit`.
    let sandbox: URL
    /// Released in `deinit` (nonisolated); NSPasteboard is safe to release from any thread.
    nonisolated(unsafe) let pasteboard: NSPasteboard
    let idle = FakeIdleSource()
    let signals = FakeLockSignalSource()
    let ticker = FakeTicker()
    let dockBadge = RecordedDockBadge()
    /// The network path the connectivity monitor sees (nothing is reported until a test sends
    /// one, so the app starts online).
    let pathSource = FakeNetworkPathSource()
    /// The connectivity monitor's own clock, so its debounce never mixes with other sleepers.
    let networkClock = ManualClock()
    /// The recovery key issued when the harness created its vault (nil for `.none`).
    let recoveryKey: RecoveryKey?

    /// - Parameters:
    ///   - ghStatus: the fixed gh status, or nil to use the live probe over the scripted gh
    ///     (call ``installFakeGH(version:)`` first).
    ///   - fileInspector: what the gh trust check reads; a `FakeGHFileInspector` models a gh that
    ///     another user owns. Nil uses the real file system (the sandboxed fake gh).
    init(
        vault: TestVaultState = .none,
        signed: Bool = true,
        ghStatus: GHStatusModel? = .unknown,
        fileInspector: (any GHFileInspecting)? = nil
    ) async throws {
        clock = ManualClock()
        biometrics = FakeBiometricKeyStore()
        capabilities = FakeBuildCapabilities()
        if !signed {
            capabilities.accessGroup = nil
        }
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("fxvault-apptests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("io.fractalx.fxvault.tests.\(UUID().uuidString)"))
        let session = try VaultSession.inMemory()
        let data = VaultDataComponents.makeOffline(
            session: session,
            runner: runner,
            clock: clock,
            sandbox: sandbox,
            fileInspector: fileInspector ?? SystemGHFileInspector()
        )
        let github = data.github
        let manager = try VaultManager(
            session: session,
            policy: .testing,
            biometricStore: biometrics,
            capabilities: capabilities,
            clock: clock,
            onLock: { github.purgeTokens() }
        )
        switch vault {
        case .none:
            recoveryKey = nil
        case .locked:
            recoveryKey = try await manager.create(password: testPassword)
            manager.lock()
        case .unlocked:
            recoveryKey = try await manager.create(password: testPassword)
        }
        let preferences = PreferencesManager(store: InMemoryPreferencesStore())
        let autoLock = AutoLockManager(
            clock: clock,
            idleSource: idle,
            signalSource: signals,
            ticker: ticker,
            timeout: { preferences.autoLockTimeout }
        )
        let probe: any GHStatusProbing = if let ghStatus {
            FixedGHStatusProbe(ghStatus)
        } else {
            GitHubEnvironmentStatusProbe(github: github, preferences: preferences)
        }
        container = AppContainer(
            mode: .test,
            vaultManager: manager,
            data: data,
            preferences: preferences,
            clipboard: ClipboardManager(pasteboard: pasteboard, clock: clock),
            autoLock: autoLock,
            ghStatusProbe: probe,
            dockBadge: dockBadge,
            passphraseGenerator: try? PassphraseGenerator.bundled(),
            vaultDirectory: nil,
            clock: clock,
            connectivity: ConnectivityMonitor(source: pathSource, clock: networkClock)
        )
        app = AppViewModel(container: container)
        await app.ghProbeTask?.value
    }

    var vaultManager: VaultManager {
        container.vaultManager
    }

    var preferences: PreferencesManager {
        container.preferences
    }

    var data: VaultDataComponents {
        container.data
    }

    /// The string on the private pasteboard (tests may read it; the app never does).
    var pasteboardString: String? {
        pasteboard.string(forType: .string)
    }

    /// Stores the DEK in the fake Touch ID item (Touch ID enabled).
    func enableTouchID() async throws {
        try await vaultManager.enableBiometrics(password: testPassword)
    }

    // MARK: - Scripted gh

    /// Writes an executable placeholder `gh` in the sandbox, points the gh override at it and
    /// scripts `gh --version`. The file is never run: the fake runner answers every call.
    @discardableResult
    func installFakeGH(version: String = Limits.minimumGHVersion) throws -> String {
        let directory = sandbox.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gh = directory.appendingPathComponent("gh", isDirectory: false)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: TestFixtures.executableMode], ofItemAtPath: gh.path)
        try FileManager.default.setAttributes([.posixPermissions: TestFixtures.directoryMode], ofItemAtPath: directory.path)
        runner.stub(
            argumentsPrefix: ["--version"],
            with: .success("gh version \(version) (2026-09-01)\nhttps://github.com/cli/cli/releases/tag/v\(version)\n")
        )
        preferences.ghPathOverride = gh.path
        return gh.path
    }

    /// Scripts `gh auth status --json hosts` (every call; replaces an earlier script).
    func stubAuthStatus(_ json: String) {
        runner.replaceStub(argumentsPrefix: ["auth", "status"], with: .success(json))
    }

    /// Scripts `gh auth token` (every call).
    func stubToken() {
        runner.stub(argumentsPrefix: ["auth", "token"], with: .success(TestFixtures.token + "\n"))
    }

    /// Scripts the interactive shell probe (`/bin/zsh -i -l -c …`, every call; replaces an
    /// earlier script).
    func stubShellProbe(_ output: String) {
        runner.replaceStub(argumentsPrefix: ["-i", "-l", "-c"], with: .success(output))
    }

    /// How many times the shell probe ran.
    var shellProbeCount: Int {
        runner.invocations.filter { $0.executablePath == VaultDataComponents.OfflineSandbox.shellPath }.count
    }

    /// Stages a repository with items in the vault (no gh needed; the vault must be unlocked).
    @discardableResult
    func stageRepository(
        owner: String = TestFixtures.owner,
        name: String = TestFixtures.repoName,
        visibility: RepoVisibility = .private,
        items: [RepoCreationItemDraftModel] = [],
        environments: [RepoCreationEnvironmentDraftModel] = []
    ) async throws -> RepoID {
        let result = try await data.creation.stage(RepoCreationDraftModel(
            accountLogin: TestFixtures.account,
            ownerLogin: owner,
            ownerType: owner == TestFixtures.account ? .user : .organization,
            name: name,
            visibility: visibility,
            spec: RepoCreateSpecModel(autoInit: true, cloneAfter: false),
            items: items,
            environments: environments
        ))
        return result.repositoryID
    }

    deinit {
        recoveryKey?.wipe()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: sandbox)
    }
}

/// Sample data for AppTests (synthetic names only, lessons.md).
enum TestFixtures {
    static let account = "user-a"
    static let otherAccount = "user-b"
    static let owner = "Example-Org"
    static let repoName = "example-repo"
    static let token = "fake-token-apptests"
    static let executableMode = 0o755
    static let directoryMode = 0o755

    static let authStatusTwoAccounts = """
    {"hosts":{"github.com":[
     {"state":"success","active":true,"host":"github.com","login":"user-a","tokenSource":"keyring","scopes":"gist, read:org, repo","gitProtocol":"ssh"},
     {"state":"success","active":false,"host":"github.com","login":"user-b","tokenSource":"keyring","scopes":"gist","gitProtocol":"ssh"}
    ]}}
    """

    static let authStatusNoAccounts = """
    {"hosts":{}}
    """

    /// Two Enterprise Managed User accounts (`handle_shortcode`, synthetic), both in the keyring:
    /// the v0.3.1 root cause, which 0.3.0 dropped as invalid logins.
    static let authStatusManagedUsers = """
    {"hosts":{"github.com":[
     {"state":"success","active":true,"host":"github.com","login":"user1_acme","tokenSource":"keyring","scopes":"admin:public_key, gist, read:org, repo","gitProtocol":"https"},
     {"state":"success","active":false,"host":"github.com","login":"user1-e_acme","tokenSource":"keyring","scopes":"admin:public_key, gist, read:org, repo","gitProtocol":"https"}
    ]}}
    """

    /// What the shell probe prints (``FakeGHOutput/shellProbe(ghPath:variables:configDir:path:)``).
    static func shellProbeOutput(ghPath: String?, variables: [String] = [], configDir: String? = nil) -> String {
        FakeGHOutput.shellProbe(ghPath: ghPath, variables: variables, configDir: configDir)
    }

    /// One `gh repo view` / `gh repo list` entry (``FakeGHOutput/repo(owner:name:permission:)``).
    static func repoJSON(owner: String, name: String, permission: String = "WRITE") -> String {
        FakeGHOutput.repo(owner: owner, name: name, permission: permission)
    }

    static func item(_ kind: ConfigKind, _ name: String, _ value: String) -> RepoCreationItemDraftModel {
        RepoCreationItemDraftModel(kind: kind, name: name, value: SecretBytes(utf8: value))
    }

    /// Waits until `condition` holds, yielding to the observation tasks (database streams
    /// deliver on their own schedule). Returns false after `timeout`.
    @MainActor
    static func eventually(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// Records what features asked the main window to do.
@MainActor
final class ActionRecorder {
    var presented: [MainSheet] = []
    var refreshes: [MainRefreshRequest] = []
    var selections: [RepoID] = []
    var openings: [OpenedScope] = []
    /// Folders shown (v0.7.0: a new folder, a linked copy's folder).
    var openedFolders: [FolderID] = []
    /// Destinations shown (v0.8.0).
    var openedDestinations: [DestinationID] = []

    struct OpenedScope: Equatable {
        let repositoryID: RepoID
        let scope: ConfigScope
    }
}

extension TestHarness {
    /// Feature dependencies over this harness with recording actions.
    func dependencies(recorder: ActionRecorder, isGitHubReady: Bool = false) -> FeatureDependencies {
        FeatureDependencies(container: container, actions: MainActions(
            present: { recorder.presented.append($0) },
            refresh: { recorder.refreshes.append($0) },
            beginSyncActivity: { [app] in app.beginSyncActivity() },
            addLockObserver: { [app] observer in app.addLockObserver(observer) },
            isGitHubReady: { isGitHubReady },
            select: { recorder.selections.append($0) },
            open: { recorder.openings.append(ActionRecorder.OpenedScope(repositoryID: $0, scope: $1)) },
            openFolder: { recorder.openedFolders.append($0) },
            openDestination: { recorder.openedDestinations.append($0) }
        ))
    }
}

extension TestHarness {
    /// The vault row of a repository, read now.
    func repository(_ id: RepoID) -> RepoModel? {
        try? data.config.changeSet(repositoryID: id)?.repository
    }
}
