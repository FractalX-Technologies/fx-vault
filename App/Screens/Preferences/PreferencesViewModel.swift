import Foundation
import Observation
import VaultCore
import VaultData

/// The Settings window (§10 Preferences), aware of the vault phase.
///
/// - **General** and **Advanced** hold no secrets and work in every phase.
/// - **Security** and **Accounts** need the vault unlocked; otherwise they show "Unlock FX Vault
///   to change these settings", and their sheets are dismissed on lock.
/// - **Reset vault** (Advanced) needs an existing vault, the master password and the typed word.
@Observable
final class PreferencesViewModel: LockObserving {
    enum Tab: String, CaseIterable, Identifiable {
        case general
        case security
        case accounts
        case advanced

        var id: String {
            rawValue
        }
    }

    var selectedTab: Tab = .general

    // Reset vault (Advanced)
    var isShowingResetVault = false
    var resetPassword = ""
    var resetConfirmationText = ""
    private(set) var isResetting = false
    private(set) var resetError: ErrorPresentationModel?

    let security: SecuritySettingsViewModel
    let accounts: AccountsSettingsViewModel

    @ObservationIgnored private let app: AppViewModel

    init(app: AppViewModel) {
        self.app = app
        security = SecuritySettingsViewModel(app: app)
        accounts = AccountsSettingsViewModel(app: app)
        app.addLockObserver(self)
    }

    var phase: VaultPhase {
        app.phase
    }

    /// True when the Security and Accounts tabs can be used.
    var isVaultSettingsAvailable: Bool {
        app.phase == .unlocked
    }

    // MARK: - General

    var autoLockMinutes: Int {
        get { app.container.preferences.autoLockMinutes }
        set { app.container.preferences.autoLockMinutes = newValue }
    }

    var autoLockOptions: [Int] {
        PreferencesManager.autoLockOptions
    }

    var cloneFolderURL: URL? {
        app.container.preferences.cloneFolderURL
    }

    func setCloneFolder(_ url: URL?) {
        app.container.preferences.setCloneFolder(url)
    }

    // MARK: - Advanced

    var ghPathOverride: String {
        get { app.container.preferences.ghPathOverride ?? "" }
        set { app.container.preferences.ghPathOverride = newValue }
    }

    var ghStatus: GHStatusModel {
        app.ghStatus
    }

    func recheckGH() async {
        await app.refreshGHStatus()
    }

    /// The vault folder, or nil for an in-memory vault (previews, tests).
    var vaultFolderURL: URL? {
        app.container.vaultDirectory
    }

    /// The word the user types to confirm a reset. Not localized: it is a fixed token, like a
    /// command, so documentation and support can quote it.
    static let resetConfirmationWord = "reset"

    var canStartReset: Bool {
        app.phase != .onboarding
    }

    var canResetVault: Bool {
        canStartReset
            && !resetPassword.isEmpty
            && resetConfirmationText.trimmingCharacters(in: .whitespaces).lowercased() == Self.resetConfirmationWord
            && !isResetting
    }

    func beginResetVault() {
        guard canStartReset else { return }
        clearResetFields()
        isShowingResetVault = true
    }

    func cancelResetVault() {
        clearResetFields()
        isShowingResetVault = false
    }

    /// Erases the vault after verifying the master password (D30) and returns to onboarding.
    func resetVault() async {
        guard canResetVault else { return }
        isResetting = true
        resetError = nil
        defer { isResetting = false }
        do {
            try await app.container.vaultManager.resetVault(password: resetPassword)
            clearResetFields()
            isShowingResetVault = false
            app.didResetVault()
        } catch {
            resetError = error.presentation
        }
    }

    // MARK: - LockObserving

    func vaultDidLock() {
        // Reset works while locked, but a lock still dismisses the sheet and drops the password.
        cancelResetVault()
        security.dismissAll()
    }

    private func clearResetFields() {
        resetPassword = ""
        resetConfirmationText = ""
        resetError = nil
    }
}
