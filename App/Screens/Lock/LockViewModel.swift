import Observation
import VaultCore
import VaultData

/// The lock screen (§10.2): master password, Touch ID and the way to the recovery reset.
///
/// Touch ID auto-prompts at most once per lock, only while FX Vault is the active app and its
/// scene is active, and only when Touch ID is available (enabled, signed build, no restart or
/// 14-day password requirement, §5.5).
@Observable
final class LockViewModel: LockObserving {
    var password = ""
    private(set) var isUnlocking = false
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

    /// A Touch ID state worth explaining under the password field (lockout, missing sensor), or
    /// nil when there is nothing to say (not enabled, unsigned build).
    var biometricNotice: String? {
        if let passwordRequiredReason {
            return passwordRequiredReason.localizedMessage
        }
        guard case .unavailable(let reason) = biometricStatus else { return nil }
        switch reason {
        case .lockout, .notAvailable, .notEnrolled, .passcodeNotSet:
            return reason.localizedMessage
        case .notEnabled, .unsignedBuild:
            return nil
        }
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
        guard canUnlockWithPassword else { return }
        isUnlocking = true
        error = nil
        defer { isUnlocking = false }
        do {
            try await app.container.vaultManager.unlock(password: password)
            password = ""
            app.didUnlock()
        } catch {
            self.error = error.presentation
            refreshBiometricStatus()
        }
    }

    func unlockWithTouchID() async {
        guard showsTouchIDButton, !isUnlocking else { return }
        isUnlocking = true
        error = nil
        defer { isUnlocking = false }
        do {
            try await app.container.vaultManager.unlockWithBiometrics(prompt: Self.unlockPrompt)
            password = ""
            app.didUnlock()
        } catch {
            refreshBiometricStatus()
            switch error {
            case VaultError.passwordFallbackRequested:
                passwordFocusRequest += 1
            case VaultError.cancelled, VaultError.locked, VaultError.passwordRequired, VaultError.biometryUnavailable:
                // Cancel leaves the password field as it is; requirements show as a notice.
                break
            default:
                self.error = error.presentation
            }
        }
    }

    /// Prompts for Touch ID once per lock, when the rules allow it (§10.2).
    func autoPromptIfAllowed(isAppActive: Bool, isSceneActive: Bool) async {
        guard isAppActive, isSceneActive, !hasAutoPrompted, !isUnlocking else { return }
        refreshBiometricStatus()
        guard showsTouchIDButton else { return }
        hasAutoPrompted = true
        await unlockWithTouchID()
    }

    // MARK: - Recovery

    func showRecoveryReset() {
        password = ""
        error = nil
        isShowingRecoveryReset = true
    }

    func recoveryResetDidCancel() {
        isShowingRecoveryReset = false
    }

    // MARK: - LockObserving

    func vaultDidLock() {
        password = ""
        error = nil
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
