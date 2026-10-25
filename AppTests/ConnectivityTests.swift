import Foundation
import GitHubKit
import SyncEngine
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Records what a ``ConnectivityMonitor`` told its observers.
@MainActor
final class ConnectivityRecorder: ConnectivityObserving {
    private(set) var changes: [Bool] = []

    func connectivityDidChange(isOnline: Bool) {
        changes.append(isOnline)
    }
}

/// The NWPathMonitor-based monitor over a hand-driven path source (v0.2.0 connectivity banner).
@MainActor
@Suite("Connectivity monitor")
struct ConnectivityMonitorTests {
    static let debounce = Theme.Durations.connectivityDebounce
    static let tick = Duration.milliseconds(1)

    let source = FakeNetworkPathSource()
    let clock = ManualClock()
    let recorder = ConnectivityRecorder()

    func makeMonitor() -> ConnectivityMonitor {
        let monitor = ConnectivityMonitor(source: source, clock: clock)
        monitor.addObserver(recorder)
        monitor.start()
        return monitor
    }

    /// Lets the pending change sleep, then moves the clock past the debounce.
    func settle(_ monitor: ConnectivityMonitor) async {
        await clock.waitForSleepers(count: 1)
        clock.advance(by: Self.debounce)
        await monitor.settleTask?.value
    }

    @Test func startsOnlineAndStartsOnce() {
        let monitor = ConnectivityMonitor(source: source, clock: clock)
        #expect(monitor.isOnline)
        #expect(!source.isStarted)
        monitor.start()
        monitor.start()
        #expect(source.isStarted)
        #expect(monitor.isStarted)
        monitor.stop()
        #expect(!source.isStarted)
        #expect(!monitor.isStarted)
    }

    @Test func theFirstReportAppliesAtOnce() {
        let monitor = makeMonitor()
        source.send(.offline)
        #expect(!monitor.isOnline)
        #expect(recorder.changes == [false])
        #expect(monitor.settleTask == nil)
    }

    @Test func satisfiedAndUnsatisfiedTransitionsWaitForTheDebounce() async {
        let monitor = makeMonitor()
        source.send(.online)
        #expect(recorder.changes.isEmpty)

        source.send(.offline)
        #expect(monitor.isOnline)
        await clock.waitForSleepers(count: 1)
        clock.advance(by: Self.debounce - Self.tick)
        #expect(monitor.isOnline)
        clock.advance(by: Self.tick)
        await monitor.settleTask?.value
        #expect(!monitor.isOnline)
        #expect(recorder.changes == [false])

        source.send(.online)
        #expect(!monitor.isOnline)
        await settle(monitor)
        #expect(monitor.isOnline)
        #expect(recorder.changes == [false, true])
    }

    @Test func aConstrainedPathIsOnline() async {
        let monitor = makeMonitor()
        source.send(NetworkPathModel(status: .satisfied, isConstrained: true))
        #expect(monitor.isOnline)
        #expect(monitor.isConstrained)
        #expect(recorder.changes.isEmpty)

        // Low Data Mode ends: nothing to report.
        source.send(.online)
        #expect(!monitor.isConstrained)
        #expect(monitor.settleTask == nil)

        // A route that must be brought up first (on-demand VPN) is offline.
        source.send(NetworkPathModel(status: .requiresConnection))
        await settle(monitor)
        #expect(!monitor.isOnline)

        source.send(NetworkPathModel(status: .satisfied, isConstrained: true))
        await settle(monitor)
        #expect(monitor.isOnline)
        #expect(recorder.changes == [false, true])
    }

    @Test func aFlappingPathNeverReachesTheUI() async {
        let monitor = makeMonitor()
        source.send(.online)
        for _ in 0..<3 {
            source.send(.offline)
            source.send(.online)
        }
        #expect(monitor.settleTask == nil)
        #expect(await TestFixtures.eventually { clock.sleeperCount == 0 })
        clock.advance(by: Self.debounce * 2)
        #expect(monitor.isOnline)
        #expect(recorder.changes.isEmpty)

        // Only the state the path settles in counts, once.
        source.send(.offline)
        source.send(.online)
        source.send(.offline)
        await settle(monitor)
        #expect(!monitor.isOnline)
        #expect(recorder.changes == [false])
    }

    @Test func moreUpdatesOfTheSameTransitionDoNotRestartTheWait() async {
        let monitor = makeMonitor()
        source.send(.online)
        source.send(.offline)
        await clock.waitForSleepers(count: 1)
        let pending = monitor.settleTask
        clock.advance(by: Self.debounce - Self.tick)
        // Interfaces going away one by one report several offline paths.
        source.send(NetworkPathModel(status: .requiresConnection))
        source.send(.offline)
        #expect(monitor.settleTask == pending)
        #expect(clock.sleeperCount == 1)
        clock.advance(by: Self.tick)
        await monitor.settleTask?.value
        #expect(!monitor.isOnline)
        #expect(recorder.changes == [false])
    }

    @Test func stopDropsAPendingChange() async {
        let monitor = makeMonitor()
        source.send(.online)
        source.send(.offline)
        await clock.waitForSleepers(count: 1)
        monitor.stop()
        clock.advance(by: Self.debounce)
        #expect(monitor.settleTask == nil)
        #expect(monitor.isOnline)
        #expect(recorder.changes.isEmpty)
    }

    @Test func observersAreHeldWeakly() {
        let monitor = ConnectivityMonitor(source: source, clock: clock)
        var observer: ConnectivityRecorder? = ConnectivityRecorder()
        if let observer {
            monitor.addObserver(observer)
        }
        weak let released = observer
        observer = nil
        #expect(released == nil)
        monitor.start()
        source.send(.offline)
        #expect(!monitor.isOnline)
    }

    @Test func fixedSourceReportsItsPath() {
        let monitor = ConnectivityMonitor(source: FixedNetworkPathSource(.offline), clock: clock)
        monitor.start()
        #expect(!monitor.isOnline)
    }
}

/// "GitHub isn't responding": fed by the outcome of the gh calls the app already makes.
@MainActor
@Suite("GitHub reachability")
struct GitHubReachabilityTests {
    nonisolated static let unreachable: [any Error] = [
        GHError.network,
        GHError.timeout,
        RepoCatalogError.github(.network),
        DriftRepositoryError.github(.timeout),
        DriftRepositoryError.sync(.github(.network)),
        GitHubEnvironmentError.github(.network),
        RepoCreationError.github(.timeout),
        SyncRepositoryError.sync(.github(.network)),
        SyncError.github(.timeout),
    ]

    nonisolated static let answered: [any Error] = [
        GHError.notFound,
        GHError.serverError(status: 502),
        GHError.rateLimited,
        GHError.validation("already exists"),
        GHError.tokenRevoked,
        RepoCatalogError.github(.samlRequired(nil)),
        DriftRepositoryError.github(.writeAccessRequired),
    ]

    nonisolated static let local: [any Error] = [
        CancellationError(),
        GHError.cancelled,
        GHError.notInstalled,
        GHError.launchFailed,
        GHError.unexpected(exitCode: 1),
        VaultError.locked,
        RepoCatalogError.vault(.locked),
        RepoCatalogError.repositoryNotFound,
        DriftRepositoryError.stale,
        GitHubEnvironmentError.accountNotFound,
    ]

    @Test(arguments: unreachable)
    func networkAndTimeoutMeanNotResponding(_ error: any Error) {
        let reachability = GitHubReachability()
        reachability.record(error)
        #expect(!reachability.isResponding)
        reachability.recordSuccess()
        #expect(reachability.isResponding)
    }

    @Test(arguments: answered)
    func anAnswerFromGitHubMeansResponding(_ error: any Error) {
        let reachability = GitHubReachability()
        reachability.record(GHError.network)
        reachability.record(error)
        #expect(reachability.isResponding)
    }

    @Test(arguments: local)
    func localFailuresSayNothing(_ error: any Error) {
        let reachability = GitHubReachability()
        reachability.record(error)
        #expect(reachability.isResponding)
        reachability.record(GHError.network)
        reachability.record(error)
        #expect(!reachability.isResponding)
    }

    @Test func retryWithoutAnyReportClearsTheState() async {
        let reachability = GitHubReachability()
        reachability.record(GHError.network)
        var sawRetrying = false
        await reachability.retry {
            sawRetrying = reachability.isRetrying
        }
        #expect(sawRetrying)
        #expect(!reachability.isRetrying)
        #expect(reachability.isResponding)
    }

    @Test func retryKeepsTheStateWhenGitHubStillDoesNotAnswer() async {
        let reachability = GitHubReachability()
        reachability.record(GHError.network)
        await reachability.retry {
            reachability.record(DriftRepositoryError.github(.timeout))
        }
        #expect(!reachability.isResponding)

        await reachability.retry {
            reachability.recordSuccess()
        }
        #expect(reachability.isResponding)
    }

    @Test func resetForgetsTheState() {
        let reachability = GitHubReachability()
        reachability.record(GHError.timeout)
        reachability.reset()
        #expect(reachability.isResponding)
    }
}

/// The banner, the offline gating of every gh-backed action and the drift re-check on reconnect.
@MainActor
@Suite("Connectivity in the main window")
struct MainConnectivityTests {
    static let ready = GHStatusModel.ready(version: Limits.minimumGHVersion, path: "/opt/homebrew/bin/gh")

    /// Selects the imported repository and waits for its drift check on open.
    static func open(_ id: RepoID, in main: MainViewModel) async throws -> RepoDetailViewModel {
        #expect(await TestFixtures.eventually {
            main.sidebar.sections.flatMap(\.owners).flatMap(\.repos).contains { $0.importedRepoID == id }
        })
        main.sidebar.select(repositoryID: id)
        let detail = try #require(main.detail)
        #expect(detail.repositoryID == id)
        await detail.driftTask?.value
        return detail
    }

    /// Moves the harness network path to `path` past the debounce.
    static func settle(_ harness: TestHarness, to path: NetworkPathModel) async {
        harness.pathSource.send(path)
        await harness.networkClock.waitForSleepers(count: 1)
        harness.networkClock.advance(by: Theme.Durations.connectivityDebounce)
        await harness.container.connectivity.settleTask?.value
    }

    static func listCalls(_ harness: TestHarness, _ prefix: [String]) -> Int {
        harness.runner.invocations.filter { Array($0.arguments.prefix(prefix.count)) == prefix }.count
    }

    @Test func theAppStartsTheMonitor() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        #expect(harness.pathSource.isStarted)
        #expect(harness.container.connectivity.isOnline)
        harness.app.applicationWillTerminate()
        #expect(!harness.pathSource.isStarted)
    }

    @Test func bannerStates() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        let main = harness.app.makeMainViewModel()
        let reachability = harness.container.gitHubReachability
        #expect(main.connectivityBanner == nil)

        reachability.record(DriftRepositoryError.github(.network))
        #expect(main.connectivityBanner == .gitHubNotResponding(isRetrying: false))
        #expect(main.connectivityBanner?.message == "GitHub isn't responding. Try again in a moment.")

        // Offline wins over GitHub.
        harness.pathSource.send(.offline)
        #expect(main.connectivityBanner == .offline)
        #expect(
            main.connectivityBanner?.message
                == "No internet connection. Your changes stay in the vault; sync when you're back online."
        )

        // Back online: the banner hides and the GitHub state starts over.
        await Self.settle(harness, to: .online)
        #expect(main.isOnline)
        #expect(main.connectivityBanner == nil)
        #expect(reachability.isResponding)

        // Retry with nothing to call (gh never listed anything) clears the GitHub state.
        reachability.record(GHError.timeout)
        #expect(main.connectivityBanner == .gitHubNotResponding(isRetrying: false))
        await main.retryGitHub()
        #expect(main.connectivityBanner == nil)
    }

    @Test func everyGitHubActionIsDisabledOffline() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        let id = try await EnvFileFixtures.importRepositoryWithMissingSecret(harness)
        let main = harness.app.makeMainViewModel()
        try harness.data.config.addItem(
            repositoryID: id,
            scope: .repository,
            kind: .variable,
            name: "NEW_VARIABLE",
            value: SecretBytes(utf8: "FXV_FIXTURE_VALUE")
        )
        #expect(await TestFixtures.eventually { harness.app.pendingChangeCount > 0 })
        let detail = try await Self.open(id, in: main)
        let imported = try #require(main.selectedRepo)
        let listed = try #require(
            SidebarGrouping.sections(try SidebarViewModelTests.input(), query: "")
                .flatMap(\.owners).flatMap(\.repos).first { !$0.isImported }
        )
        #expect(await TestFixtures.eventually { main.scopeList?.selectedScope != nil })

        // Online: everything is available.
        #expect(main.canSync)
        #expect(main.canCreateRepository)
        #expect(main.sidebar.canAddByName)
        #expect(main.sidebar.canImport(listed))
        #expect(main.sidebar.canClone(imported))
        #expect(detail.canRefresh)
        #expect(detail.canClone)
        #expect(main.networkHelp("Sync") == "Sync")

        harness.pathSource.send(.offline)
        #expect(!main.isOnline)
        #expect(main.networkHelp("Sync") == ConnectivityCopy.offlineHelp)
        let callsBefore = harness.runner.invocations.count

        // Sync (toolbar, menu and a chained "Sync Now…").
        #expect(!main.canSync)
        main.sync()
        #expect(main.activeSheet == nil)
        main.present(.sync(SyncContext(repositoryIDs: [id])))
        #expect(main.activeSheet == nil)

        // New Repository.
        #expect(!main.canCreateRepository)
        main.newRepository()
        main.present(.createRepository(CreateRepoContext(accountLogin: nil, ownerLogin: nil)))
        #expect(main.activeSheet == nil)

        // Import repository, Add by name and Clone.
        #expect(!main.sidebar.canImport(listed))
        #expect(!main.sidebar.canAddByName)
        main.addRepositoryByName(accountLogin: TestFixtures.account)
        main.present(.addRepositoryByName(AddRepositoryContext(accountLogin: TestFixtures.account)))
        #expect(main.activeSheet == nil)
        #expect(!main.sidebar.canClone(imported))
        let add = AddRepositoryViewModel(
            context: AddRepositoryContext(accountLogin: TestFixtures.account),
            catalog: harness.data.catalog,
            connectivity: harness.container.connectivity,
            gitHubReachability: harness.container.gitHubReachability
        ) { _ in }
        add.fullName = "Other-Owner/shared"
        #expect(!add.canAdd)
        #expect(await !add.add())

        // Refresh, Clone and drift checks of the open repository.
        #expect(!detail.canRefresh)
        #expect(!detail.canClone)
        await detail.refresh()
        await detail.refreshDrift()
        let driftTask = detail.driftTask
        detail.checkDriftOnOpen()
        #expect(detail.driftTask == driftTask)
        await main.sidebar.reload()
        await main.retryGitHub()
        #expect(harness.runner.invocations.count == callsBefore, "No gh call runs while offline")

        // Local work and sharing a file (no internet needed) stay available.
        #expect(main.canImportEnv)
        #expect(detail.canEdit)
        #expect(main.canShareProject)
        main.shareProject()
        #expect({ if case .shareExport = main.activeSheet { true } else { false } }())
        main.activeSheet = nil

        // Back online: everything returns.
        await Self.settle(harness, to: .online)
        await main.reconnectTask?.value
        #expect(main.canSync)
        #expect(main.canCreateRepository)
        #expect(main.sidebar.canAddByName)
        #expect(main.sidebar.canImport(listed))
        #expect(detail.canRefresh)
        #expect(add.canAdd)
    }

    @Test func theDriftCheckRunsAgainWhenTheConnectionReturns() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        let id = try await EnvFileFixtures.importRepositoryWithMissingSecret(harness)
        let main = harness.app.makeMainViewModel()
        let detail = try await Self.open(id, in: main)
        #expect(detail.driftReport != nil)
        let secretLists = Self.listCalls(harness, ["secret", "list"])
        let authChecks = Self.listCalls(harness, ["auth", "status"])

        harness.pathSource.send(.online)
        await Self.settle(harness, to: .offline)
        #expect(!main.isOnline)
        #expect(main.reconnectTask == nil)
        harness.container.gitHubReachability.record(GHError.network)
        // Reopening the repository while offline skips its check.
        detail.checkDriftOnOpen()

        await Self.settle(harness, to: .online)
        let reconnect = try #require(main.reconnectTask)
        await reconnect.value
        #expect(Self.listCalls(harness, ["secret", "list"]) > secretLists)
        #expect(detail.driftReport != nil)
        #expect(detail.driftError == nil)
        #expect(main.connectivityBanner == nil)
        // The repository lists never loaded, so they load now.
        #expect(Self.listCalls(harness, ["auth", "status"]) > authChecks)
    }

    @Test func aShortDropReusesARecentDriftCheckAndReconnectsNeverOverlap() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        let id = try await EnvFileFixtures.importRepositoryWithMissingSecret(harness)
        let main = harness.app.makeMainViewModel()
        let detail = try await Self.open(id, in: main)
        #expect(detail.driftReport != nil)
        harness.pathSource.send(.online)
        let secretLists = Self.listCalls(harness, ["secret", "list"])

        // Two drops in a row, each back within the drift debounce of the last check.
        await Self.settle(harness, to: .offline)
        await Self.settle(harness, to: .online)
        let first = try #require(main.reconnectTask)
        await Self.settle(harness, to: .offline)
        await Self.settle(harness, to: .online)
        let second = try #require(main.reconnectTask)
        #expect(first != second)
        await second.value
        // The recent check is reused: no full re-list of the repository.
        #expect(Self.listCalls(harness, ["secret", "list"]) == secretLists)
        #expect(detail.driftReport != nil)
        #expect(detail.driftError == nil)
    }

    @Test func aReconnectWhileLockedChecksNothing() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: Self.ready)
        let main = harness.app.makeMainViewModel()
        harness.pathSource.send(.offline)
        harness.container.gitHubReachability.record(GHError.network)
        main.lock()
        let calls = harness.runner.invocations.count

        await Self.settle(harness, to: .online)
        #expect(main.reconnectTask == nil)
        #expect(harness.container.gitHubReachability.isResponding)
        #expect(harness.runner.invocations.count == calls)
    }

    @Test func aNetworkFailureShowsGitHubNotResponding() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        try harness.installFakeGH()
        harness.stubAuthStatus(TestFixtures.authStatusTwoAccounts)
        harness.stubToken()
        await harness.app.refreshGHStatus()
        let main = harness.app.makeMainViewModel()
        let failure = FakeCommandRunner.Response.failure(stderr: "dial tcp: lookup api.github.com: no such host")
        for _ in 0...Limits.idempotentRetries {
            harness.runner.enqueue(failure) { Array($0.prefix(2)) == ["repo", "view"] }
        }
        let add = AddRepositoryViewModel(
            context: AddRepositoryContext(accountLogin: TestFixtures.account),
            catalog: harness.data.catalog,
            connectivity: harness.container.connectivity,
            gitHubReachability: harness.container.gitHubReachability
        ) { _ in }
        add.fullName = "Other-Owner/shared"
        // The scheduler retries reads after a backoff on the harness clock: move it along.
        let lookUp = Task { await add.add() }
        let driver = Task {
            while !Task.isCancelled {
                if harness.clock.sleeperCount > 0 {
                    harness.clock.advance(by: Timeouts.idempotentRetryBackoff * Limits.idempotentRetries)
                }
                await Task.yield()
            }
        }
        let added = await lookUp.value
        driver.cancel()
        #expect(!added)
        #expect(add.error != nil)
        #expect(Self.listCalls(harness, ["repo", "view"]) == Limits.idempotentRetries + 1)
        #expect(main.connectivityBanner == .gitHubNotResponding(isRetrying: false))

        // GitHub answers again (here: the repository does not exist).
        harness.runner.enqueue(.failure(stderr: "GraphQL: Could not resolve to a Repository with the name 'Other-Owner/shared'. (repository)")) {
            Array($0.prefix(2)) == ["repo", "view"]
        }
        #expect(await !add.add())
        #expect(main.connectivityBanner == nil)
    }

    @Test func onlyGitHubRoutesNeedTheInternet() {
        let id = RepoID()
        #expect(MainSheet.sync(SyncContext(repositoryIDs: nil)).needsInternet)
        #expect(MainSheet.createRepository(CreateRepoContext(accountLogin: nil, ownerLogin: nil)).needsInternet)
        #expect(MainSheet.addRepositoryByName(AddRepositoryContext(accountLogin: TestFixtures.account)).needsInternet)
        #expect(!MainSheet.shareExport(ShareExportContext(selection: .repository(id))).needsInternet)
        #expect(!MainSheet.envExport(EnvExportContext(repositoryID: id, scope: .repository)).needsInternet)
        #expect(!MainSheet.driftReview(DriftReviewContext(repositoryID: id)).needsInternet)
    }

    @Test func syncHelpExplainsOffline() {
        let button = SyncToolbarButton(count: 2, isSyncing: false, isEnabled: false, unavailableReason: ConnectivityCopy.offlineHelp) {}
        #expect(button.unavailableReason == ConnectivityCopy.offlineHelp)
        #expect(SyncToolbarButton.help(count: 2, isSyncing: false) == "Push 2 pending changes to GitHub")
    }
}
