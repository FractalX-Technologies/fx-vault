import Observation
import VaultCore
import VaultData

/// The one-time "Unlock FX Vault with Touch ID" offer, shown on the lock screen right after a
/// password unlock (v0.1.1) when ``AppViewModel/shouldOfferTouchID(afterInvalidation:)`` allows
/// it. The vault is already unlocked; the main window follows when the offer is answered.
///
/// - **Enable** runs the existing `VaultManager.enableBiometrics(password:)` flow with the
///   password just typed. The password is held only here, and dropped after Enable (success or
///   failure), Not Now, or a lock.
/// - **Not Now** is remembered (``AppViewModel/recordTouchIDOfferAnswer()``), so is a successful
///   Enable; a failed Enable shows the error and Continue counts as Not Now (Settings › Security
///   can try again).
@Observable
final class TouchIDOfferViewModel: Identifiable {
    private(set) var isWorking = false
    private(set) var error: ErrorPresentationModel?
    /// True once the offer was answered or discarded; nothing runs after that.
    private(set) var isFinished = false
    /// Touch ID was turned off by an enrollment change (the subtitle says so).
    let isAfterInvalidation: Bool

    @ObservationIgnored private let app: AppViewModel
    @ObservationIgnored private var password: String
    @ObservationIgnored private let onFinish: () -> Void

    init(app: AppViewModel, password: String, afterInvalidation: Bool, onFinish: @escaping () -> Void) {
        self.app = app
        self.password = password
        isAfterInvalidation = afterInvalidation
        self.onFinish = onFinish
    }

    /// Enable is offered until it was tried once.
    var canEnable: Bool {
        !password.isEmpty && !isWorking && !isFinished
    }

    /// "Turn On Touch ID": enables Touch ID with the password just typed.
    func enable() async {
        guard canEnable else { return }
        isWorking = true
        error = nil
        let typed = password
        password = ""
        defer { isWorking = false }
        do {
            try await app.container.vaultManager.enableBiometrics(password: typed)
            guard !isFinished else { return }
            app.recordTouchIDOfferAnswer()
            finish()
        } catch {
            guard !isFinished else { return }
            if case VaultError.locked = error {
                finish()
                return
            }
            AppLog.vault.error("Enabling Touch ID from the unlock offer failed")
            self.error = error.presentation
        }
    }

    /// "Not Now" (and "Continue" after a failed Enable): remembered, never offered again.
    func notNow() {
        guard !isWorking, !isFinished else { return }
        app.recordTouchIDOfferAnswer()
        finish()
    }

    /// A lock while the offer is on screen: drop the password, answer nothing, call nobody.
    func discard() {
        password = ""
        isFinished = true
    }

    private func finish() {
        password = ""
        isFinished = true
        onFinish()
    }
}
