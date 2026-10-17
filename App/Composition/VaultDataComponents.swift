import DestinationKit
import EnvTools
import Foundation
import GitHubKit
import SharingKit
import VaultCore
import VaultData

/// Every VaultData repository the app uses, built once per vault session by ``AppContainer``
/// (one per process: the composition root's lifetime).
///
/// Lifetimes and sharing (§4.3, ARCHITECTURE.md "Composition"):
/// - ``github`` is the only `GHSchedulerProviding`: one gh queue per account, one token cache.
///   Its ``GitHubEnvironmentRepository/tokenCache`` is the cache the lock path purges
///   (`VaultManager(onLock:)` calls ``GitHubEnvironmentRepository/purgeTokens()``).
/// - ``sync``, ``drift``, ``catalog``, ``creation`` and ``sharing`` are actors holding
///   per-session state (the running sync, drift reports and pending-verification counts,
///   added-by-name rows, template caches). They are never rebuilt; ``AppViewModel`` resets
///   ``drift`` and cancels the running sync on lock.
/// - git needs the login-shell environment (PATH, `SSH_AUTH_SOCK`, §8 A2), which is probed
///   asynchronously. ``cloner`` and the `.env` export git checks therefore resolve it on first
///   use (``GitServiceProvider``) instead of capturing an empty one at launch. Clone through
///   ``cloner``; ``creation`` is built without git and is used for staging, owners, templates
///   and name checks only.
struct VaultDataComponents {
    let session: VaultSession
    let github: GitHubEnvironmentRepository
    let catalog: RepoCatalogRepository
    let config: ConfigRepository
    let envFiles: EnvFileRepository
    let sync: SyncRepository
    let creation: RepoCreationRepository
    /// Clones through the account's mapped SSH alias with the probed shell environment. Also the
    /// cloner ``sync`` uses for "Clone to my Mac" after a create.
    let cloner: any RepoCloning
    let drift: DriftRepository
    let sharing: SharingRepository
    /// Nearby chat conversations and the items that can be attached (v0.2.0).
    let chat: ChatRepository
    /// This device's teammate keys and the paired devices (v0.5.0).
    let team: TeamRepository
    /// Shared spaces (v0.6.0): the versioned scopes teammates keep in sync. ``sync`` gates and
    /// publishes through it.
    let spaces: SpaceRepository
    /// Folders of secrets and variables (v0.7.0).
    let folders: FolderRepository
    /// Runtime destinations of repositories and the provider connections (v0.8.0).
    let destinations: DestinationRepository
    /// The stage Overview and `fxvault.yml` (v0.8.0).
    let overview: StageOverviewRepository
    /// Destination Sync, Refresh and import over HTTPS (v0.8.0).
    let destinationSync: DestinationSyncRepository
    /// Token checks and the Add Destination pickers (v0.8.0).
    let destinationAccess: DestinationAccessRepository
    /// The `az` tokens; reset on lock.
    let azureTokens: ShellResolvingAzureTokens

    /// Builds every repository over `session`.
    ///
    /// - Parameters:
    ///   - runner: `ProcessRunner` in the live app, `FakeCommandRunner` in previews and tests.
    ///   - identity: the process identity gh, git and ssh run as.
    ///   - workingDirectory: the empty working directory of child processes (§5.10).
    ///   - shellPath: the login shell to probe; nil reads it from the password database.
    ///   - sshConfigParser: nil reads `~/.ssh/config` of `identity`.
    ///   - fileInspector: what the gh trust check reads (a `FakeGHFileInspector` in tests that
    ///     model a gh owned by another user).
    static func make(
        session: VaultSession,
        runner: any CommandRunning,
        identity: ProcessIdentityModel,
        workingDirectory: URL,
        clock: any VaultClock,
        shellPath: String? = nil,
        sshConfigParser: SSHConfigParser? = nil,
        fileInspector: any GHFileInspecting = SystemGHFileInspector(),
        deriver: any KeyDeriving = Argon2idSharingDeriver(),
        writePolicy: WriteCollaboratorPolicy = .default,
        transport: any HTTPTransporting = URLSessionTransport()
    ) -> VaultDataComponents {
        let github = GitHubEnvironmentRepository(
            database: session.database,
            runner: runner,
            identity: identity,
            workingDirectory: workingDirectory,
            clock: clock,
            tokenCache: GHTokenCache(),
            shellPath: shellPath,
            sshConfigParser: sshConfigParser,
            fileInspector: fileInspector
        )
        let gitProvider = GitServiceProvider(
            github: github,
            runner: runner,
            identity: identity,
            workingDirectory: workingDirectory,
            clock: clock
        )
        let cloner = ShellResolvingRepoCloner(
            session: session,
            github: github,
            gitProvider: gitProvider,
            clock: clock,
            writePolicy: writePolicy
        )
        let catalog = RepoCatalogRepository(session: session, schedulers: github, clock: clock)
        // A project share's ⇣ repositories are looked up and imported through this Mac's gh
        // accounts; a gh that is not ready makes the lookup fail, which shows as unreachable.
        let sharing = SharingRepository(
            session: session,
            schedulers: github,
            deriver: deriver,
            clock: clock,
            writePolicy: writePolicy,
            repositoryAccess: CatalogShareRepositoryAccess(github: github, catalog: catalog, isGitHubReady: { true })
        )
        let spaces = SpaceRepository(session: session, schedulers: github, clock: clock)
        let azureTokens = ShellResolvingAzureTokens(
            github: github,
            runner: runner,
            identity: identity,
            workingDirectory: workingDirectory,
            fileInspector: fileInspector,
            clock: clock
        )
        let remotes = LiveDestinationRemoteProvider(
            factory: DestinationRemoteFactory(transport: transport, azureTokens: azureTokens, clock: clock)
        )
        return VaultDataComponents(
            session: session,
            github: github,
            catalog: catalog,
            config: ConfigRepository(session: session, clock: clock, writePolicy: writePolicy),
            envFiles: EnvFileRepository(
                session: session,
                gitignoreChecker: ShellResolvingGitignoreChecker(gitProvider: gitProvider),
                clock: clock,
                writePolicy: writePolicy
            ),
            sync: SyncRepository(
                session: session,
                schedulers: github,
                cloner: cloner,
                clock: clock,
                writePolicy: writePolicy,
                spaces: spaces
            ),
            creation: RepoCreationRepository(session: session, schedulers: github, git: nil, clock: clock, writePolicy: writePolicy),
            cloner: cloner,
            drift: DriftRepository(session: session, schedulers: github, clock: clock, writePolicy: writePolicy, spaces: spaces),
            sharing: sharing,
            chat: ChatRepository(session: session, sharing: sharing, clock: clock),
            team: TeamRepository(session: session, clock: clock),
            spaces: spaces,
            folders: FolderRepository(session: session, clock: clock),
            destinations: DestinationRepository(session: session, clock: clock),
            overview: StageOverviewRepository(session: session, schedulers: github),
            destinationSync: DestinationSyncRepository(session: session, remotes: remotes, clock: clock),
            destinationAccess: DestinationAccessRepository(session: session, transport: transport, azureTokens: azureTokens, clock: clock),
            azureTokens: azureTokens
        )
    }

    /// Repositories over a scripted gh (`FakeCommandRunner`) and a home folder under the
    /// temporary directory: no process is spawned and nothing under `~/Library` or `~/.ssh` is
    /// read (previews, the test host and AppTests).
    static func makeOffline(
        session: VaultSession,
        runner: FakeCommandRunner = FakeCommandRunner(),
        clock: any VaultClock,
        sandbox: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(OfflineSandbox.directoryName, isDirectory: true),
        fileInspector: any GHFileInspecting = SystemGHFileInspector()
    ) -> VaultDataComponents {
        let home = sandbox.appendingPathComponent(OfflineSandbox.homeName, isDirectory: true)
        let identity = ProcessIdentityModel(
            home: home.path,
            user: OfflineSandbox.userName,
            temporaryDirectory: sandbox.path
        )
        return make(
            session: session,
            runner: runner,
            identity: identity,
            workingDirectory: sandbox,
            clock: clock,
            shellPath: OfflineSandbox.shellPath,
            sshConfigParser: SSHConfigParser(
                sshDirectory: home.appendingPathComponent(OfflineSandbox.sshDirectoryName, isDirectory: true),
                homeDirectory: home
            ),
            fileInspector: fileInspector,
            transport: FakeHTTPTransport()
        )
    }

    /// Names used by ``makeOffline(session:runner:clock:sandbox:)``. Nothing is created on disk:
    /// the fake runner never uses the working directory and a missing ssh folder lists no hosts.
    enum OfflineSandbox {
        static let directoryName = "io.fractalx.fxvault.offline"
        static let homeName = "home"
        static let sshDirectoryName = ".ssh"
        static let userName = "user-a"
        static let shellPath = "/bin/zsh"
    }
}
