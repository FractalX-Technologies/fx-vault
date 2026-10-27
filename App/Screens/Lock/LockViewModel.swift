import Observation
import VaultCore
import VaultData

/// The lock screen (§10.2): master password, Touch ID and the way to the recovery reset.
///
/// Touch ID auto-prompts at most once per lock, only while FX Vault is the active app and its
/// scene is active, and only when Touch ID is available (enabled, signed build, no restart or
/// 14-day password requirement, §5.5).
///
/// After a password unlock the vault is unlocked at once; when
/// ``AppViewModel/shouldOfferTouchID(afterInvalidation:)`` allows it, the one-time Touch ID offer
/// (``touchIDOffer``) is answered first and the main window follows (v0.1.1).
@Observable
final class LockViewModel: LockObserving {
    var password = ""
    private(set) var isUnlocking = false
    /// The Touch ID offer on screen after a password unlock, or nil.
    private(set) var touchIDOffer: TouchIDOfferViewModel?
    private(set) var error: ErrorPresentationModel?
    private(set) var biometricStatus: BiometricUnlockStatus = .unavailable(.notEnabled)
    private(set) var hasAutoPrompted = false
    /// Incremented when the user picks the Touch ID prompt's password fallback; the screen
    /// focuses the password field on every change (§5.5).
    private(set) var passwordFocusRequest = 0
    var isShowingRecoveryReset = false

    @ObservationIgnored private let app: AppViewModel

    init(app: AppViewModel) {
        self.app = app
        app.addLockObserver(self)
        refreshBiometricStatus()
    }

    var ghStatus: GHStatusModel {
        app.ghStatus
    }

    var canUnlockWithPassword: Bool {
        !password.isEmpty && !isUnlocking
    }

    /// True when the Touch ID button is offered.
    var showsTouchIDButton: Bool {
        biometricStatus == .available
    }

    /// Why the password is required even though Touch ID is on, or nil.
    var passwordRequiredReason: PasswordRequiredReason? {
        if case .passwordRequired(let reason) = biometricStatus { return reason }
        return nil
    }

    /// A Touch ID state worth explaining under the password field, or nil when there is nothing
    /// to say (not enabled, unsigned build). While Touch ID is on but the password is required,
    /// the title is the short reason ("Password required: After a restart") and the detail
    /// explains it; lockout and a missing sensor show the detail only.
    var biometricNotice: LockNoticeModel? {
        if let passwordRequiredReason {
            return LockNoticeModel(
                title: String(
                    localized: "lock.passwordRequired.title",
                    defaultValue: "Password required: \(passwordRequiredReason.localizedShortTitle)"
                ),
                detail: passwordRequiredReason.localizedMessage
            )
        }
        guard case .unavailable(let reason) = biometricStatus else { return nil }
        switch reason {
        case .lockout, .notAvailable, .notEnrolled, .passcodeNotSet:
            return LockNoticeModel(title: nil, detail: reason.localizedMessage)
        case .notEnabled, .unsignedBuild:
            return nil
        }
    }

    /// The card's subtitle: mentions Touch ID when it can unlock right now.
    var subtitle: String {
        showsTouchIDButton
            ? String(localized: "lock.subtitle.touchID", defaultValue: "Use Touch ID or enter your master password.")
            : String(localized: "lock.subtitle", defaultValue: "Enter your master password to unlock.")
    }

    func refreshBiometricStatus() {
        do {
            biometricStatus = try app.container.vaultManager.biometricUnlockStatus()
        } catch {
            biometricStatus = .unavailable(.notEnabled)
        }
    }

    // MARK: - Unlock

    func unlockWithPassword() async {
        guard canUnlockWithPassword, touchIDOffer == nil else { return }
        isUnlocking = true
        error = nil
        defer { isUnlocking = false }
        do {
            try await app.container.vaultManager.unlock(password: password)
            // Read after the unlock: it turns Touch ID off when the enrollment changed, whatever
            // reason (restart, 14 days) the lock screen showed. Earlier turn-offs (a Touch ID
            // attempt, a ReauthGate check while unlocked) are recorded there too.
            let afterInvalidation = app.container.vaultManager.isBiometricsTurnedOffAutomatically
            let typed = password
            password = ""
            if app.shouldOfferTouchID(afterInvalidation: afterInvalidation) {
                touchIDOffer = app.makeTouchIDOfferViewModel(
                    password: typed,
                    afterInvalidation: afterInvalidation
                ) { [weak self] in
                    self?.touchIDOfferDidFinish()
                }
                app.showLockWindow()
            } else {
                app.didUnlock()
            }
        } catch {
            self.error = error.presentation
            refreshBiometricStatus()
        }
    }

    /// The offer was answered: show the main window.
    private func touchIDOfferDidFinish() {
        touchIDOffer = nil
        app.didUnlock()
    }

    func unlockWithTouchID() async {
        guard showsTouchIDButton, !isUnlocking, touchIDOffer == nil else {
            AppLog.vault.info("Touch ID unlock skipped: \(String(describing: self.biometricStatus), privacy: .public), unlocking \(self.isUnlocking), offer \(self.touchIDOffer != nil)")
            return
        }
        isUnlocking = true
        error = nil
        defer { isUnlocking = false }
        do {
            // The system prompt, from the island too: the island's own `LAAuthenticationView`
            // cancelled its check ~30 ms after it started, so no touch ever reached it (1.0.2).
            try await app.container.vaultManager.unlockWithBiometrics(prompt: Self.unlockPrompt)
            password = ""
            app.didUnlock()
        } catch {
            // VaultError cases carry reasons only; any other error logs its type alone.
            let ending = (error as? VaultError).map { String(describing: $0) } ?? String(describing: type(of: error))
            AppLog.vault.info("Touch ID unlock ended: \(ending, privacy: .public)")
            refreshBiometricStatus()
            switch error {
            case VaultError.passwordFallbackRequested:
                passwordFocusRequest += 1
            case VaultError.biometryInvalidated:
                self.error = error.presentation
            case VaultError.passwordRequired(reason: .biometryChanged):
                // The enrollment changed after the lock screen last looked: Touch ID was just
                // turned off, so the button and the notice go away. Say why.
                self.error = VaultError.biometryInvalidated.presentation
            case VaultError.cancelled, VaultError.locked, VaultError.passwordRequired, VaultError.biometryUnavailable:
                // Cancel leaves the password field as it is; requirements show as a notice.
                break
            default:
                self.error = error.presentation
            }
        }
    }

    /// The island is the unlock UI, which prompts only on request.
    var unlocksInIsland: Bool {
        app.unlocksInIsland && app.island != nil
    }

    /// Prompts for Touch ID once per lock, when the rules allow it (§10.2).
    func autoPromptIfAllowed(isAppActive: Bool, isSceneActive: Bool) async {
        guard isAppActive, isSceneActive, !hasAutoPrompted, !isUnlocking, touchIDOffer == nil else {
            AppLog.vault.info("Touch ID auto prompt skipped: active \(isAppActive), prompted \(self.hasAutoPrompted), unlocking \(self.isUnlocking), offer \(self.touchIDOffer != nil)")
            return
        }
        refreshBiometricStatus()
        guard showsTouchIDButton else {
            AppLog.vault.info("Touch ID auto prompt skipped: \(String(describing: self.biometricStatus), privacy: .public)")
            return
        }
        hasAutoPrompted = true
        await unlockWithTouchID()
    }

    /// A sleep or screen lock while already locked (Phase A only, no ``vaultDidLock()``): the
    /// next activation may prompt again.
    func vaultDidLockAgain() {
        promptAgain()
    }

    /// The next activation prompts for Touch ID even if this lock already did: a new lock, or a
    /// new request such as the quick vault's shortcut.
    func promptAgain() {
        hasAutoPrompted = false
    }

    // MARK: - Recovery

    func showRecoveryReset() {
        password = ""
        error = nil
        isShowingRecoveryReset = true
        app.showLockWindow()
    }

    func recoveryResetDidCancel() {
        isShowingRecoveryReset = false
        app.presentIsland()
    }

    // MARK: - LockObserving

    func vaultDidLock() {
        password = ""
        error = nil
        touchIDOffer?.discard()
        touchIDOffer = nil
        hasAutoPrompted = false
        isShowingRecoveryReset = false
        refreshBiometricStatus()
    }

    /// The Touch ID prompt texts (D24: built in the app).
    static var unlockPrompt: BiometricPrompt {
        BiometricPrompt(
            reason: String(localized: "touchID.prompt.unlock", defaultValue: "unlock your FX Vault"),
            fallbackTitle: String(localized: "touchID.prompt.fallback", defaultValue: "Use Master Password")
        )
    }
}
