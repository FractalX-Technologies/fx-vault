import Foundation
import GitHubKit
import Observation
import VaultCore
import VaultData

/// The Settings window (§10 Preferences), aware of the vault phase: General and Advanced hold no
/// secrets and work in every phase; Security and Accounts need the vault unlocked (their sheets
/// close on lock), except Reset vault, which needs an existing vault, the master password and
/// the typed word.
@Observable
final class PreferencesViewModel: LockObserving {
    enum Tab: String, CaseIterable, Identifiable {
        case general
        case security
        case accounts
        case sharing
        case advanced

        var id: String {
            rawValue
        }
    }

    var selectedTab: Tab = .general

    // Open at login (General), as the system last reported it.
    private(set) var loginItemStatus: LoginItemStatus
    private(set) var loginItemError: ErrorPresentationModel?

    // Copy Diagnostics (Advanced)
    private(set) var isCollectingDiagnostics = false
    private(set) var hasCopiedDiagnostics = false

    // Reset vault (Security)
    var isShowingResetVault = false
    var resetPassword = ""
    var resetConfirmationText = ""
    private(set) var isResetting = false
    private(set) var resetError: ErrorPresentationModel?

    let security: SecuritySettingsViewModel
    let accounts: AccountsSettingsViewModel
    /// The share files this Mac sent (v0.9.0).
    let sharing: SharingSettingsViewModel

    @ObservationIgnored private let app: AppViewModel

    init(app: AppViewModel) {
        self.app = app
        security = SecuritySettingsViewModel(app: app)
        accounts = AccountsSettingsViewModel(app: app)
        sharing = SharingSettingsViewModel(app: app)
        loginItemStatus = app.container.loginItem.status
        app.addLockObserver(self)
    }

    var phase: VaultPhase {
        app.phase
    }

    /// The tab the main window asked for (``AppViewModel/requestedSettingsTab``).
    var requestedTab: Tab? {
        app.requestedSettingsTab
    }

    /// Switches to the requested tab, and opens the requested Security sheet, once.
    func showRequestedTab() {
        guard let tab = app.requestedSettingsTab else { return }
        selectedTab = tab
        if let sheet = app.requestedSecuritySheet {
            security.present(sheet)
        }
        app.clearSettingsTabRequest()
    }

    /// True when the Security and Accounts tabs can be used.
    var isVaultSettingsAvailable: Bool {
        app.phase == .unlocked
    }

    // MARK: - General

    var quickVaultShortcut: QuickVaultShortcutModel {
        get { app.container.preferences.quickVaultShortcut }
        set {
            app.container.preferences.quickVaultShortcut = newValue
            if !isRecordingShortcut {
                app.registerQuickVaultHotKey()
            }
        }
    }

    /// The shortcut box listens: the shortcut is off meanwhile, so pressing it records it
    /// instead of opening the quick vault; the end registers the new one (1.0 Q1).
    var isRecordingShortcut = false {
        didSet {
            guard isRecordingShortcut != oldValue else { return }
            app.setQuickVaultHotKeySuspended(isRecordingShortcut)
        }
    }

    /// On while registered, also while System Settings still has to allow it.
    var opensAtLogin: Bool {
        loginItemStatus != .off
    }

    /// Reads the status again: the user can change it in System Settings at any time.
    func refreshLoginItem() {
        loginItemStatus = app.container.loginItem.status
    }

    /// **Open at login**: registers or unregisters FX Vault with `SMAppService`.
    func setOpensAtLogin(_ isOn: Bool) {
        let loginItem = app.container.loginItem
        loginItemError = nil
        do {
            if isOn {
                try loginItem.register()
            } else {
                try loginItem.unregister()
            }
        } catch {
            loginItemError = ErrorPresentationModel(
                title: String(localized: "settings.general.openAtLogin.failed", defaultValue: "Open at login could not be changed"),
                message: error.localizedDescription
            )
        }
        loginItemStatus = loginItem.status
    }

    /// **Open Login Items** when the system waits for the user's approval.
    func openLoginItemsSettings() {
        app.container.loginItem.openSystemSettings()
    }

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

    /// **Check Again**: probes the shell again, then detects gh.
    func recheckGH() async {
        await app.refreshGHStatus(refreshingShell: true)
    }

    /// The gh the user trusted although another user owns it (v0.3.1), or nil.
    var trustedGHBinary: GHTrustedBinaryModel? {
        app.container.preferences.trustedGHBinary
    }

    /// The owner of ``trustedGHBinary``, as the user database names it.
    var trustedGHOwner: GHBinaryOwnerModel? {
        trustedGHBinary.map {
            GHBinaryOwnerModel(uid: $0.ownerUID, name: app.container.data.github.ownerName(for: $0.ownerUID))
        }
    }

    /// **Revoke**: FX Vault stops running the trusted gh and asks again when it finds it.
    func revokeTrustedGH() async {
        await app.revokeTrustedGHBinary()
    }

    /// **Copy Diagnostics** (``AppViewModel/copyGHDiagnostics()``).
    func copyDiagnostics() async {
        guard !isCollectingDiagnostics else { return }
        isCollectingDiagnostics = true
        defer { isCollectingDiagnostics = false }
        await app.copyGHDiagnostics()
        hasCopiedDiagnostics = true
    }

    /// Copy on a command row (the `--diagnose` command): plain text, never cleared.
    func copyCommand(_ command: String) {
        app.container.clipboard.copyCommand(command)
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
