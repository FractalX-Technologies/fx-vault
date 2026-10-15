import AppKit
import Observation
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

/// App-wide state shared by every scene: the vault phase, the lock procedure, gh status and the
/// pending-change count shown on the Sync button and the Dock.
@Observable
final class AppViewModel {
    private(set) var phase: VaultPhase
    private(set) var ghStatus: GHStatusModel = .checking
    /// Pending changes across all repositories (Sync button label and Dock badge).
    private(set) var pendingChangeCount = 0
    /// True while a sync runs (Sync button shows progress; arrives with Milestone 3).
    private(set) var isSyncing = false
    /// Incremented by every lock that dropped keys or left a phase.
    private(set) var lockCount = 0
    private(set) var lastLockTrigger: LockTrigger?

    @ObservationIgnored let container: AppContainer
    @ObservationIgnored private var lockObservers: [WeakLockObserver] = []
    @ObservationIgnored private var ghProbeTask: Task<Void, Never>?

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
        ghProbeTask = Task { [weak self] in
            await self?.refreshGHStatus()
        }
    }

    // MARK: - Lock procedure (§5.8)

    /// Locks the vault. Phase A runs synchronously before anything can suspend: the keyring is
    /// dropped (VaultManager also purges the gh token cache and invalidates the Touch ID
    /// context), then ``phase`` becomes `.locked`, which removes every screen that shows
    /// values. Phase B follows: observers dismiss sheets, the clipboard is cleared if FX Vault
    /// still owns it, a modal panel is aborted, and the WAL is checkpointed off the main actor.
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
    }

    private func runLockPhaseB() {
        lockObservers.removeAll { $0.observer == nil }
        for entry in lockObservers {
            entry.observer?.vaultDidLock()
        }
        container.clipboard.clearIfOwned()
        if container.hasSideEffects, NSApp.modalWindow != nil {
            NSApp.abortModal()
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
    }

    /// Called when onboarding's Done step closes.
    func completeOnboarding() {
        switch container.vaultManager.state {
        case .noVault:
            phase = .onboarding
        case .locked:
            phase = .locked
        case .unlocked:
            container.autoLock.recordInteraction()
            phase = .unlocked
        }
    }

    /// Called after Preferences › Advanced › Reset vault erased everything.
    func didResetVault() {
        container.preferences.isRecoveryKeyConfirmationPending = false
        setPendingChangeCount(0)
        lockCount += 1
        runLockPhaseB()
        phase = .onboarding
    }

    // MARK: - Sync count

    /// Updates the Sync button count and the Dock badge (set by the sync repository later).
    func setPendingChangeCount(_ count: Int) {
        pendingChangeCount = max(0, count)
        container.dockBadge.showBadge(count: pendingChangeCount)
    }

    // MARK: - gh status

    /// Runs the gh probe (A1–A3). Never blocks onboarding or unlock.
    func refreshGHStatus() async {
        ghStatus = .checking
        ghStatus = await container.ghStatusProbe.probe()
    }

    // MARK: - App lifecycle

    /// `applicationWillTerminate`: clear our clipboard contents, drop the keys and checkpoint.
    func applicationWillTerminate() {
        container.clipboard.clearIfOwned()
        container.autoLock.stop()
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
        container.autoLock.observeClose(of: window)
    }

    // MARK: - View models

    func makeOnboardingViewModel() -> OnboardingViewModel {
        OnboardingViewModel(app: self)
    }

    func makeLockViewModel() -> LockViewModel {
        LockViewModel(app: self)
    }

    func makeRecoveryResetViewModel() -> RecoveryResetViewModel {
        RecoveryResetViewModel(app: self)
    }

    func makePreferencesViewModel() -> PreferencesViewModel {
        PreferencesViewModel(app: self)
    }

    func makeMainViewModel() -> MainViewModel {
        MainViewModel(app: self, content: EmptyMainContentSource())
    }
}

private struct WeakLockObserver {
    weak var observer: (any LockObserving)?
}
