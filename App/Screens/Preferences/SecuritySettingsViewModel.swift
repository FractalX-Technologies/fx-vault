import Observation
import VaultCore
import VaultCrypto
import VaultData

/// Preferences › Security (§10, D30): Touch ID, change master password (with rotation), new
/// recovery key, clipboard info. Every action needs the vault unlocked and the master password;
/// none of them accepts Touch ID.
@Observable
final class SecuritySettingsViewModel {
    enum Sheet: String, Identifiable {
        case enableTouchID
        case disableTouchID
        case changePassword
        case newRecoveryKey
        /// Shows a recovery key returned by a password change with rotation or a new-key request.
        case showRecoveryKey

        var id: String {
            rawValue
        }
    }

    var activeSheet: Sheet?
    private(set) var isBiometricsEnabled = false
    /// Why Touch ID cannot be enabled (`.unsignedBuild` shows the official-release note), or nil.
    private(set) var biometricsUnavailableReason: BiometryUnavailableReason?

    // Sheet fields
    var currentPassword = ""
    var newPassword = "" {
        didSet { newPasswordStrength = PasswordStrength.evaluate(newPassword) }
    }
    var newPasswordConfirmation = ""
    /// "My password may be compromised: rotate the vault key" (on by default, §5.2).
    var rotateVaultKey = true
    private(set) var newPasswordStrength = PasswordStrength.evaluate("")
    private(set) var isWorking = false
    private(set) var error: ErrorPresentationModel?
    private(set) var didChangePassword = false

    private(set) var recoveryKeyGroups: [String] = []
    private(set) var hasCopiedRecoveryKey = false

    @ObservationIgnored private let app: AppViewModel
    @ObservationIgnored private var recoveryKey: RecoveryKey?

    init(app: AppViewModel) {
        self.app = app
        refresh()
    }

    var isAvailable: Bool {
        app.phase == .unlocked
    }

    /// Reloads the Touch ID state (call when the tab appears and after unlock).
    func refresh() {
        let manager = app.container.vaultManager
        biometricsUnavailableReason = manager.biometricsAvailability()
        isBiometricsEnabled = (try? manager.isBiometricsEnabled()) ?? false
    }

    var canToggleTouchID: Bool {
        isAvailable && biometricsUnavailableReason == nil
    }

    // MARK: - Presenting

    /// The Touch ID toggle asks for the master password before changing anything.
    func requestTouchID(enabled: Bool) {
        guard isAvailable, enabled != isBiometricsEnabled else { return }
        if enabled, !canToggleTouchID { return }
        present(enabled ? .enableTouchID : .disableTouchID)
    }

    func present(_ sheet: Sheet) {
        guard isAvailable else { return }
        clearFields()
        activeSheet = sheet
    }

    func dismissSheet() {
        if activeSheet == .showRecoveryKey {
            wipeRecoveryKey()
        }
        clearFields()
        activeSheet = nil
    }

    /// Lock: dismiss everything and wipe any key on screen (§5.8 Phase B).
    func dismissAll() {
        wipeRecoveryKey()
        clearFields()
        activeSheet = nil
    }

    // MARK: - Touch ID

    func confirmTouchIDChange() async {
        guard let sheet = activeSheet, sheet == .enableTouchID || sheet == .disableTouchID else { return }
        guard !currentPassword.isEmpty else { return }
        await perform {
            if sheet == .enableTouchID {
                try await app.container.vaultManager.enableBiometrics(password: currentPassword)
            } else {
                try await app.container.vaultManager.disableBiometrics(password: currentPassword)
            }
            // A choice made here answers the one-time unlock offer too: never offer it again.
            app.recordTouchIDOfferAnswer()
            refresh()
            dismissSheet()
        }
    }

    // MARK: - Change password

    var newPasswordsMatch: Bool {
        !newPasswordConfirmation.isEmpty && newPassword == newPasswordConfirmation
    }

    var canChangePassword: Bool {
        !currentPassword.isEmpty && newPasswordStrength.isAcceptable && newPasswordsMatch && !isWorking
    }

    func changePassword() async {
        guard activeSheet == .changePassword, canChangePassword else { return }
        await perform {
            let key = try await app.container.vaultManager.changePassword(
                current: currentPassword,
                new: newPassword,
                rotate: rotateVaultKey
            )
            didChangePassword = true
            refresh()
            if let key {
                show(key)
            } else {
                dismissSheet()
            }
        }
    }

    // MARK: - New recovery key

    func createNewRecoveryKey() async {
        guard activeSheet == .newRecoveryKey, !currentPassword.isEmpty, !isWorking else { return }
        await perform {
            let key = try await app.container.vaultManager.newRecoveryKey(password: currentPassword)
            show(key)
        }
    }

    func copyRecoveryKey() {
        guard let recoveryKey else { return }
        app.container.clipboard.copy(recoveryKey.formatted)
        hasCopiedRecoveryKey = true
    }

    /// "I saved it": wipe the key and close the sheet.
    func acknowledgeRecoveryKey() {
        app.container.preferences.isRecoveryKeyConfirmationPending = false
        dismissSheet()
    }

    // MARK: - Private

    private func show(_ key: RecoveryKey) {
        wipeRecoveryKey()
        clearFields()
        recoveryKey = key
        recoveryKeyGroups = key.groups
        app.container.preferences.isRecoveryKeyConfirmationPending = true
        activeSheet = .showRecoveryKey
    }

    private func perform(_ operation: () async throws -> Void) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            if !error.isCancellation {
                self.error = error.presentation
            }
        }
    }

    private func wipeRecoveryKey() {
        recoveryKey?.wipe()
        recoveryKey = nil
        recoveryKeyGroups = []
        hasCopiedRecoveryKey = false
    }

    private func clearFields() {
        currentPassword = ""
        newPassword = ""
        newPasswordConfirmation = ""
        rotateVaultKey = true
        error = nil
    }
}
