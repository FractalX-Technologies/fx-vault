import AppKit
import GitHubKit
import Observation
import SharingKit
import SyncEngine
import VaultCore
import VaultData

/// The top-level state of the vault, which decides the root screen.
enum VaultPhase: Equatable {
    /// No vault exists yet (or onboarding has not finished): show onboarding.
    case onboarding
    /// A vault exists and its keys are not in memory.
    case locked
    /// The vault keys are in memory.
    case unlocked
}

/// Something that must react to a lock (Phase B, §5.8): dismiss sheets, drop typed passwords,
/// wipe a recovery key on screen.
protocol LockObserving: AnyObject {
    func vaultDidLock()
}

/// Held by the sync sheet for the whole run (§5.7, D16): it suspends the inactivity auto-lock
/// (every other trigger still locks) and makes the Sync button show progress.
///
/// Call ``end()`` when the run finishes, fails or is cancelled (a `defer` in the task that awaits
/// the run's outcome). A lock ends every activity.
final class SyncActivity {
    private var assertion: SyncActivityAssertion?
    private let onEnd: (SyncActivity) -> Void

    fileprivate init(assertion: SyncActivityAssertion?, onEnd: @escaping (SyncActivity) -> Void) {
        self.assertion = assertion
        self.onEnd = onEnd
    }

    /// An activity no ``AppViewModel`` tracks and that holds no assertion (SwiftUI previews).
    static func untracked() -> SyncActivity {
        SyncActivity(assertion: nil) { _ in }
    }

    var isActive: Bool {
        assertion != nil
    }

    /// Releases the auto-lock assertion. Idempotent.
    func end() {
        guard let assertion else { return }
        assertion.release()
        self.assertion = nil
        onEnd(self)
    }
}

/// App-wide state shared by every scene: the vault phase, the lock procedure, gh status, the
/// pending-change count shown on the Sync button and the Dock, running syncs and the `.fxvault`
/// files waiting to be imported.
@Observable
final class AppViewModel {
    private(set) var phase: VaultPhase
    private(set) var ghStatus: GHStatusModel = .checking
    /// Bumped by ``accountsDidChange()``; the main window reloads its accounts when it changes.
    private(set) var accountsRevision = 0
    /// True while a gh probe runs (the first one also shows ``GHStatusModel/checking``).
    private(set) var isCheckingGH = false
    /// Pending changes across all repositories (Sync button label and Dock badge).
    private(set) var pendingChangeCount = 0
    /// Pending and blocked counts per repository (live, from `ConfigRepository`).
    private(set) var pendingCounts: PendingCountsModel = .empty
    /// Pending destination changes per repository (live, from `DestinationRepository`, v0.8.0).
    private(set) var destinationPendingCounts: [RepoID?: Int] = [:]
    /// True while at least one ``SyncActivity`` is active (the Sync button shows progress).
    private(set) var isSyncing = false
    /// Incremented by every lock that dropped keys or left a phase.
    private(set) var lockCount = 0
    private(set) var lastLockTrigger: LockTrigger?
    /// `.fxvault` files opened from Finder or AirDrop, oldest first (§10 Scenes). The main
    /// window imports them one by one after unlock.
    private(set) var pendingImports: [URL] = []
    /// Onboarding just finished: ``ConnectScreen`` (choose what to import) comes before the main
    /// window.
    private(set) var isFirstConnectPending = false
    /// The user chose "Not Now" on ``GHSetupScreen`` for this launch.
    private(set) var isGHSetupDeferred = false
    /// The result of the launch reconciliation after the last unlock (§7.3), nil until it ran.
    private(set) var lastReconciliation: SyncReconciliationModel?

    @ObservationIgnored let container: AppContainer
    @ObservationIgnored private var lockObservers: [WeakLockObserver] = []
    @ObservationIgnored private var syncActivities: [WeakSyncActivity] = []
    @ObservationIgnored private(set) var ghProbeTask: Task<Void, Never>?
    @ObservationIgnored private(set) var reconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCountsTask: Task<Void, Never>?
    @ObservationIgnored private var destinationCountsTask: Task<Void, Never>?
    /// Opens (or brings back) the main window; set by the main window's root view, which has the
    /// SwiftUI `openWindow` action.
    @ObservationIgnored private var mainWindowOpener: (() -> Void)?
    @ObservationIgnored private weak var mainWindow: NSWindow?
    /// The one lock model, shared by the notch island and the window's recovery and Touch ID offer.
    @ObservationIgnored private(set) lazy var lockScreen = LockViewModel(app: self)
    /// The unlock UI while locked (1.0). Nil without side effects (tests, previews), where the
    /// window's lock screen stays.
    @ObservationIgnored private(set) lazy var island: NotchIslandController? =
        container.hasSideEffects ? NotchIslandController(lock: lockScreen) : nil

    /// The file extension of share files (§9.1; UTType `io.fractalx.fxvault.share`).
    static let shareFileExtension = "fxvault"

    init(container: AppContainer) {
        self.container = container
        phase = switch container.vaultManager.state {
        case .noVault: .onboarding
        case .locked: .locked
        case .unlocked: .unlocked
        }
        container.autoLock.start { [weak self] trigger in
            self?.lock(trigger: trigger)
        }
        container.connectivity.start()
        ghProbeTask = Task { [weak self] in
            await self?.refreshGHStatus()
        }
        observePendingCounts()
        if phase == .unlocked {
            startReconciliation()
        }
    }

    // MARK: - Lock procedure (§5.8)

    /// Locks the vault. Phase A runs synchronously before anything can suspend: the keyring is
    /// dropped (VaultManager also purges the gh token cache and invalidates the Touch ID
    /// context), then ``phase`` becomes `.locked`, which removes every screen that shows
    /// values. Phase B follows: observers dismiss sheets, running syncs are cancelled, drift
    /// state is reset, the clipboard is cleared if FX Vault still owns it, a modal panel is
    /// aborted, and the WAL is checkpointed off the main actor.
    func lock(trigger: LockTrigger) {
        let manager = container.vaultManager
        let state = manager.state
        guard state != .noVault else { return }
        // Phase A
        manager.lock()
        let leftPhase = phase != .locked
        if leftPhase {
            phase = .locked
        }
        guard leftPhase || state == .unlocked else { return }
        lockCount += 1
        lastLockTrigger = trigger
        // Phase B
        runLockPhaseB()
        presentIsland()
    }

    // MARK: - Notch island

    /// While locked, the island is the unlock UI and the main window closes (1.0 brief).
    func presentIsland() {
        guard phase == .locked, let island else { return }
        island.present()
        // Closing the window fires the window-close lock trigger, a no-op while locked.
        mainWindow?.close()
    }

    /// Recovery and the Touch ID offer need the window: the island steps aside.
    func showLockWindow() {
        island?.dismiss()
        requestMainWindow()
    }

    private func runLockPhaseB() {
        // In memory only: after a lock the main window follows the unlock, like a relaunch.
        isFirstConnectPending = false
        lockObservers.removeAll { $0.observer == nil }
        for entry in lockObservers {
            entry.observer?.vaultDidLock()
        }
        endAllSyncActivities()
        reconciliationTask?.cancel()
        reconciliationTask = nil
        container.clipboard.clearIfOwned()
        container.clipboard.forgetCopiedItems()
        if container.hasSideEffects, NSApp.modalWindow != nil {
            NSApp.abortModal()
        }
        let sync = container.data.sync
        let drift = container.data.drift
        let azureTokens = container.data.azureTokens
        Task {
            await sync.currentRun?.cancel()
            await drift.reset()
            await azureTokens.reset()
        }
        let manager = container.vaultManager
        Task.detached(priority: .utility) {
            do {
                try manager.checkpoint()
            } catch {
                AppLog.vault.error("WAL checkpoint after lock failed")
            }
        }
    }

    /// Registers `observer` for Phase B. Held weakly.
    func addLockObserver(_ observer: any LockObserving) {
        lockObservers.removeAll { $0.observer == nil || $0.observer === observer }
        lockObservers.append(WeakLockObserver(observer: observer))
    }

    // MARK: - Phase transitions

    /// Called after a password, Touch ID or recovery unlock finished.
    func didUnlock() {
        guard container.vaultManager.state == .unlocked else {
            phase = .locked
            return
        }
        container.autoLock.recordInteraction()
        phase = .unlocked
        island?.dismissUnlocked()
        requestMainWindow()
        startReconciliation()
    }

    /// Called when onboarding's last step closes; an unlocked vault goes on to the Connect phase.
    func completeOnboarding() {
        switch container.vaultManager.state {
        case .noVault:
            phase = .onboarding
        case .locked:
            phase = .locked
        case .unlocked:
            container.autoLock.recordInteraction()
            isFirstConnectPending = true
            phase = .unlocked
            startReconciliation()
        }
    }

    /// The Connect phase closed (imported, or Not Now): the main window follows.
    func finishFirstConnect() {
        isFirstConnectPending = false
    }

    /// Called after Preferences › Advanced › Reset vault erased everything.
    func didResetVault() {
        container.preferences.isRecoveryKeyConfirmationPending = false
        setPendingChangeCount(0)
        pendingImports.removeAll()
        lockCount += 1
        runLockPhaseB()
        phase = .onboarding
    }

    // MARK: - Touch ID offer (v0.1.1)

    /// True when a password unlock should be followed by the one-time "Unlock FX Vault with
    /// Touch ID" offer: the vault is unlocked, the build is signed with the keychain access group
    /// and Touch ID can run on this Mac (`biometricsAvailability() == nil`), Touch ID is off, and
    /// the user has not answered the offer before. Unsigned builds never qualify.
    ///
    /// - Parameter afterInvalidation: Touch ID was on and FX Vault turned it off by itself
    ///   (`VaultManager.isBiometricsTurnedOffAutomatically`, usually an enrollment change); the
    ///   offer then comes back once even if it was answered before.
    func shouldOfferTouchID(afterInvalidation: Bool) -> Bool {
        let manager = container.vaultManager
        guard manager.state == .unlocked, manager.biometricsAvailability() == nil else { return false }
        guard let isEnabled = try? manager.isBiometricsEnabled(), !isEnabled else { return false }
        return afterInvalidation || !container.preferences.hasAnsweredTouchIDOffer
    }

    /// Remembers that the offer was answered (Enable, Not Now, or a change in Settings), which
    /// also settles an automatic turn-off.
    func recordTouchIDOfferAnswer() {
        container.preferences.hasAnsweredTouchIDOffer = true
        container.vaultManager.acknowledgeBiometricsTurnedOff()
    }

    // MARK: - Launch reconciliation (§7.3)

    /// After every unlock: prunes the sync journal and reconciles rows a crash or quit left
    /// `in_flight` or `indeterminate`, by re-listing on GitHub. Waits for gh detection first, so
    /// the per-account queues exist; rows of unavailable accounts stay for the next unlock.
    private func startReconciliation() {
        reconciliationTask?.cancel()
        let probe = ghProbeTask
        let sync = container.data.sync
        reconciliationTask = Task { [weak self] in
            await probe?.value
            guard !Task.isCancelled else { return }
            do {
                let result = try await sync.prepareAfterUnlock()
                self?.lastReconciliation = result
            } catch {
                AppLog.vault.error("Launch reconciliation failed")
            }
        }
    }

    // MARK: - Sync count and activity

    /// Updates the Sync button count and the Dock badge.
    func setPendingChangeCount(_ count: Int) {
        pendingChangeCount = max(0, count)
        container.dockBadge.showBadge(count: pendingChangeCount)
    }

    /// Follows `ConfigRepository.observePendingCounts()` and (v0.8.0) the destinations' pending
    /// changes for the whole app lifetime. The streams need no keys, so the Dock badge stays right
    /// while locked.
    private func observePendingCounts() {
        let config = container.data.config
        pendingCountsTask = Task { [weak self] in
            do {
                for try await counts in config.observePendingCounts() {
                    guard let self else { return }
                    pendingCounts = counts
                    updatePendingChangeCount()
                }
            } catch {
                AppLog.vault.error("Pending count observation ended")
            }
        }
        let destinations = container.data.destinations
        destinationCountsTask = Task { [weak self] in
            do {
                for try await counts in destinations.observePendingCounts() {
                    guard let self else { return }
                    destinationPendingCounts = counts
                    updatePendingChangeCount()
                }
            } catch {
                AppLog.vault.error("Destination pending count observation ended")
            }
        }
    }

    private func updatePendingChangeCount() {
        setPendingChangeCount(pendingCounts.total + destinationPendingCounts.values.reduce(0, +))
    }

    /// GitHub and destination changes waiting in one repository (the sidebar).
    func pendingChangeCount(of repositoryID: RepoID) -> Int {
        pendingCounts.counts(for: repositoryID).pending + (destinationPendingCounts[repositoryID] ?? 0)
    }

    /// Starts a sync activity (the sync sheet holds it for the whole run).
    func beginSyncActivity() -> SyncActivity {
        let activity = SyncActivity(assertion: container.autoLock.beginSyncActivity()) { [weak self] ended in
            self?.syncActivityDidEnd(ended)
        }
        syncActivities.removeAll { $0.activity == nil }
        syncActivities.append(WeakSyncActivity(activity: activity))
        isSyncing = true
        return activity
    }

    private func syncActivityDidEnd(_ activity: SyncActivity) {
        syncActivities.removeAll { $0.activity == nil || $0.activity === activity }
        isSyncing = syncActivities.contains { $0.activity?.isActive == true }
    }

    private func endAllSyncActivities() {
        let activities = syncActivities.compactMap(\.activity)
        for activity in activities {
            activity.end()
        }
        syncActivities.removeAll()
        isSyncing = false
    }

    // MARK: - gh status

    /// Runs the gh probe (A1–A3). Never blocks onboarding or unlock. The last known status stays
    /// in place while a re-check runs (``isCheckingGH``), so ``GHSetupScreen`` does not flicker
    /// away during **Check Again**; only the first probe shows `.checking`.
    ///
    /// - Parameter refreshingShell: probe the user's shell again first (every **Check Again**),
    ///   so a changed `~/.zshrc` (PATH, `GH_CONFIG_DIR`, a removed `GH_TOKEN`) counts at once.
    func refreshGHStatus(refreshingShell: Bool = false) async {
        isCheckingGH = true
        defer { isCheckingGH = false }
        ghStatus = await container.ghStatusProbe.probe(refreshingShell: refreshingShell)
        if ghStatus.isReady {
            isGHSetupDeferred = false
        }
    }

    /// **Trust This gh** (§5.10 consented trust): records the gh's path and owner, then detects
    /// again.
    func trustGHBinary(_ binary: GHTrustedBinaryModel) async {
        container.preferences.trustGHBinary(binary)
        await refreshGHStatus()
    }

    /// **Revoke** (Preferences › Advanced): forgets the trusted gh, then detects again.
    func revokeTrustedGHBinary() async {
        container.preferences.revokeTrustedGHBinary()
        await refreshGHStatus()
    }

    /// True when ``GHSetupScreen`` replaces the main window (after unlock, gh needs attention,
    /// and the user did not choose "Not Now").
    var showsGHSetup: Bool {
        phase == .unlocked && ghStatus.needsSetup && !isGHSetupDeferred
    }

    /// "Not Now" on ``GHSetupScreen``: work offline until the next launch or Check Again.
    func deferGHSetup() {
        isGHSetupDeferred = true
    }

    /// Settings › Accounts read gh's accounts again (Check Again): the main window lists them
    /// again too, so an account logged in from Terminal appears without a relaunch.
    func accountsDidChange() {
        accountsRevision += 1
    }

    // MARK: - Share files (§10 Scenes)

    /// Queues `.fxvault` files opened from Finder, AirDrop or a URL, and brings the main window
    /// back. Other URLs are ignored. The main window imports them after unlock.
    func openShareFiles(_ urls: [URL]) {
        var added = false
        for url in urls where Self.isShareFile(url) {
            let standardized = url.standardizedFileURL
            guard !pendingImports.contains(standardized) else { continue }
            pendingImports.append(standardized)
            added = true
        }
        guard added else { return }
        requestMainWindow()
    }

    /// Removes and returns the oldest pending import, once the vault is unlocked.
    func takeNextPendingImport() -> URL? {
        guard phase == .unlocked, !pendingImports.isEmpty else { return nil }
        return pendingImports.removeFirst()
    }

    static func isShareFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == shareFileExtension
    }

    // MARK: - Main window

    /// Called by the main window's root view with its `openWindow` action.
    func setMainWindowOpener(_ opener: @escaping () -> Void) {
        mainWindowOpener = opener
    }

    /// Activates FX Vault and opens the main window if it was closed.
    func requestMainWindow() {
        if container.hasSideEffects {
            NSApp.activate()
        }
        mainWindowOpener?()
    }

    // MARK: - App lifecycle

    /// `applicationWillTerminate`: clear our clipboard contents, drop the keys and checkpoint.
    func applicationWillTerminate() {
        container.clipboard.clearIfOwned()
        container.clipboard.forgetCopiedItems()
        container.autoLock.stop()
        container.connectivity.stop()
        pendingCountsTask?.cancel()
        destinationCountsTask?.cancel()
        guard container.vaultManager.state != .noVault else { return }
        container.vaultManager.lock()
        do {
            try container.vaultManager.checkpoint()
        } catch {
            AppLog.vault.error("WAL checkpoint at quit failed")
        }
    }

    /// The main window appeared: closing it locks the vault (D16) and it is never restored with
    /// state (§5.11).
    func attachMainWindow(_ window: NSWindow) {
        window.isRestorable = false
        mainWindow = window
        container.autoLock.observeClose(of: window)
        // FX Vault starts locked, and the Dock reopens the window: the island unlocks instead.
        if phase == .locked, !lockScreen.isShowingRecoveryReset, lockScreen.touchIDOffer == nil {
            Task { self.presentIsland() }
        }
    }

    // MARK: - View models

    func makeOnboardingViewModel() -> OnboardingViewModel {
        OnboardingViewModel(app: self)
    }

    /// The offer after a password unlock; holds `password` only until it is answered or the vault
    /// locks.
    func makeTouchIDOfferViewModel(
        password: String,
        afterInvalidation: Bool,
        onFinish: @escaping () -> Void
    ) -> TouchIDOfferViewModel {
        TouchIDOfferViewModel(app: self, password: password, afterInvalidation: afterInvalidation, onFinish: onFinish)
    }

    func makeRecoveryResetViewModel() -> RecoveryResetViewModel {
        RecoveryResetViewModel(app: self)
    }

    func makePreferencesViewModel() -> PreferencesViewModel {
        PreferencesViewModel(app: self)
    }

    func makeGHSetupViewModel() -> GHSetupViewModel {
        GHSetupViewModel(app: self)
    }

    func makeConnectViewModel() -> ConnectViewModel {
        ConnectViewModel(app: self)
    }

    func makeMainViewModel() -> MainViewModel {
        MainViewModel(app: self)
    }
}

private struct WeakLockObserver {
    weak var observer: (any LockObserving)?
}

private struct WeakSyncActivity {
    weak var activity: SyncActivity?
}
