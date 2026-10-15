import AppKit
import Foundation
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

/// The starting state of a harness vault.
enum TestVaultState {
    case none
    case locked
    case unlocked
}

/// An `AppViewModel` over an in-memory vault, fake Touch ID, a manual clock, a private
/// pasteboard, in-memory preferences and hand-driven lock sources. No test touches the real
/// vault, keychain, clipboard or `~/Library`.
@MainActor
final class TestHarness {
    let app: AppViewModel
    let container: AppContainer
    let clock: ManualClock
    let biometrics: FakeBiometricKeyStore
    let capabilities: FakeBuildCapabilities
    /// Released in `deinit` (nonisolated); NSPasteboard is safe to release from any thread.
    nonisolated(unsafe) let pasteboard: NSPasteboard
    let idle = FakeIdleSource()
    let signals = FakeLockSignalSource()
    let ticker = FakeTicker()
    let dockBadge = RecordedDockBadge()
    /// The recovery key issued when the harness created its vault (nil for `.none`).
    let recoveryKey: RecoveryKey?

    init(vault: TestVaultState = .none, signed: Bool = true, ghStatus: GHStatusModel = .unknown) async throws {
        clock = ManualClock()
        biometrics = FakeBiometricKeyStore()
        capabilities = FakeBuildCapabilities()
        if !signed {
            capabilities.accessGroup = nil
        }
        pasteboard = NSPasteboard(name: NSPasteboard.Name("io.fractalx.fxvault.tests.\(UUID().uuidString)"))
        let manager = try VaultManager(
            session: VaultSession.inMemory(),
            policy: .testing,
            biometricStore: biometrics,
            capabilities: capabilities,
            clock: clock
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
        container = AppContainer(
            mode: .test,
            vaultManager: manager,
            preferences: preferences,
            clipboard: ClipboardManager(pasteboard: pasteboard, clock: clock),
            autoLock: autoLock,
            ghStatusProbe: FixedGHStatusProbe(ghStatus),
            dockBadge: dockBadge,
            passphraseGenerator: try? PassphraseGenerator.bundled(),
            vaultDirectory: nil
        )
        app = AppViewModel(container: container)
    }

    var vaultManager: VaultManager {
        container.vaultManager
    }

    var preferences: PreferencesManager {
        container.preferences
    }

    /// The string on the private pasteboard (tests may read it; the app never does).
    var pasteboardString: String? {
        pasteboard.string(forType: .string)
    }

    /// Stores the DEK in the fake Touch ID item (Touch ID enabled).
    func enableTouchID() async throws {
        try await vaultManager.enableBiometrics(password: testPassword)
    }

    deinit {
        recoveryKey?.wipe()
        pasteboard.releaseGlobally()
    }
}
