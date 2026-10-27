import Observation
import VaultCore
import VaultCrypto
import VaultData

/// "Forgot password? Use recovery key" (§5.2, D9): the recovery key opens the vault, a new master
/// password is set, the DEK is **always** rotated and a **new** recovery key is shown. The old
/// recovery key and the old password stop working.
///
/// With neither the password nor the recovery key, the last resort erases the vault after the
/// confirmation word (``Step/erase``) and FX Vault starts over at onboarding.
@Observable
final class RecoveryResetViewModel: LockObserving {
    enum Step: Equatable {
        case enterKey
        case showNewKey
        /// "No recovery key either": erase everything and start over.
        case erase
    }

    private(set) var step: Step = .enterKey
    var recoveryKeyText = ""
    var newPassword = "" {
        didSet { strength = PasswordStrength.evaluate(newPassword) }
    }
    var passwordConfirmation = ""
    private(set) var strength = PasswordStrength.evaluate("")
    private(set) var isWorking = false
    private(set) var error: ErrorPresentationModel?
    /// What the user typed to confirm the erase.
    var eraseConfirmationText = ""

    /// The new recovery key groups while they are on screen.
    private(set) var newRecoveryKeyGroups: [String] = []
    private(set) var hasCopiedNewKey = false
    var hasSavedNewKey = false

    @ObservationIgnored private let app: AppViewModel
    @ObservationIgnored private var newRecoveryKey: RecoveryKey?

    init(app: AppViewModel) {
        self.app = app
        app.addLockObserver(self)
    }

    var passwordsMatch: Bool {
        !passwordConfirmation.isEmpty && newPassword == passwordConfirmation
    }

    var showsMismatch: Bool {
        !passwordConfirmation.isEmpty && newPassword != passwordConfirmation
    }

    var canReset: Bool {
        !recoveryKeyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && strength.isAcceptable
            && passwordsMatch
            && !isWorking
    }

    /// Parses the key, resets the password and rotates the vault key.
    func reset() async {
        guard canReset else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        let input: RecoveryKey
        do {
            input = try RecoveryKey(parsing: recoveryKeyText)
        } catch {
            self.error = error.presentation
            return
        }
        defer { input.wipe() }
        do {
            let newKey = try await app.container.vaultManager.resetWithRecoveryKey(input, newPassword: newPassword)
            recoveryKeyText = ""
            newPassword = ""
            passwordConfirmation = ""
            newRecoveryKey = newKey
            newRecoveryKeyGroups = newKey.groups
            // Stays pending until the user says the new key is saved; if the vault locks first,
            // the main window asks for a new recovery key.
            app.container.preferences.isRecoveryKeyConfirmationPending = true
            step = .showNewKey
        } catch {
            self.error = error.presentation
        }
    }

    // MARK: - Erase

    var canErase: Bool {
        step == .erase && PreferencesViewModel.isResetConfirmed(eraseConfirmationText) && !isWorking
    }

    func beginErase() {
        cancel()
        error = nil
        step = .erase
    }

    func cancelErase() {
        eraseConfirmationText = ""
        error = nil
        step = .enterKey
    }

    /// Erases the vault with no password (both are lost) and returns to onboarding.
    func erase() async {
        guard canErase else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await app.container.vaultManager.eraseForgottenVault()
            cancelErase()
            app.didResetVault()
        } catch {
            self.error = error.presentation
        }
    }

    func copyNewRecoveryKey() {
        guard let newRecoveryKey else { return }
        app.container.clipboard.copy(newRecoveryKey.formatted)
        hasCopiedNewKey = true
    }

    var canFinish: Bool {
        step == .showNewKey && hasSavedNewKey
    }

    /// The user saved the new key: wipe it and open the vault.
    func finish() {
        guard canFinish else { return }
        wipe()
        app.container.preferences.isRecoveryKeyConfirmationPending = false
        app.didUnlock()
    }

    func cancel() {
        wipe()
        recoveryKeyText = ""
        newPassword = ""
        passwordConfirmation = ""
    }

    func vaultDidLock() {
        cancel()
        eraseConfirmationText = ""
        error = nil
        step = .enterKey
    }

    private func wipe() {
        newRecoveryKey?.wipe()
        newRecoveryKey = nil
        newRecoveryKeyGroups = []
        hasCopiedNewKey = false
        hasSavedNewKey = false
    }
}
