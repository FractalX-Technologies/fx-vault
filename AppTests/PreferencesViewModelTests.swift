import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

@MainActor
@Suite("PreferencesViewModel")
struct PreferencesViewModelTests {
    // MARK: - Every phase

    @Test func onboardingPhaseOffersOnlyGeneralAndAdvanced() async throws {
        let harness = try await TestHarness(vault: .none)
        let viewModel = PreferencesViewModel(app: harness.app)
        #expect(viewModel.phase == .onboarding)
        #expect(!viewModel.isVaultSettingsAvailable)
        #expect(!viewModel.security.isAvailable)
        #expect(!viewModel.canStartReset)
        viewModel.beginResetVault()
        #expect(!viewModel.isShowingResetVault)
        viewModel.security.present(.changePassword)
        #expect(viewModel.security.activeSheet == nil)

        viewModel.autoLockMinutes = 10
        #expect(harness.preferences.autoLockMinutes == 10)
        #expect(harness.preferences.autoLockTimeout == .seconds(600))
    }

    @Test func lockedPhaseHidesSecurityButAllowsReset() async throws {
        let harness = try await TestHarness(vault: .locked)
        let viewModel = PreferencesViewModel(app: harness.app)
        #expect(viewModel.phase == .locked)
        #expect(!viewModel.isVaultSettingsAvailable)
        #expect(!viewModel.security.isAvailable)
        #expect(viewModel.canStartReset)
    }

    /// 1.0 (D6c1): an owner's "Approve" in the sidebar opens Settings on Accounts, once.
    @Test func approveInTheSidebarOpensTheAccountsTab() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let viewModel = PreferencesViewModel(app: harness.app)
        let main = harness.app.makeMainViewModel()
        #expect(viewModel.selectedTab == .general)

        main.requestAccountsSettings()
        #expect(viewModel.requestedTab == .accounts)
        viewModel.showRequestedTab()
        #expect(viewModel.selectedTab == .accounts)
        #expect(viewModel.requestedTab == nil)

        viewModel.selectedTab = .general
        viewModel.showRequestedTab()
        #expect(viewModel.selectedTab == .general, "a request is shown once")
    }

    /// The recovery-key banner (1.0 D6c2, board Main2-Home) opens Settings › Security with the
    /// new-key sheet, the only way to get a key the user can save.
    @Test func theRecoveryBannerOpensTheNewKeySheet() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let viewModel = PreferencesViewModel(app: harness.app)
        let main = harness.app.makeMainViewModel()
        harness.container.preferences.isRecoveryKeyConfirmationPending = true
        #expect(main.showsRecoveryKeyReminder)

        main.createNewRecoveryKey()
        viewModel.showRequestedTab()
        #expect(viewModel.selectedTab == .security)
        #expect(viewModel.security.activeSheet == .newRecoveryKey)

        viewModel.security.dismissSheet()
        viewModel.showRequestedTab()
        #expect(viewModel.security.activeSheet == nil, "a request is shown once")
    }

    @Test func unlockedPhaseEnablesSecurity() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let viewModel = PreferencesViewModel(app: harness.app)
        #expect(viewModel.phase == .unlocked)
        #expect(viewModel.isVaultSettingsAvailable)
        #expect(viewModel.security.isAvailable)
        #expect(viewModel.security.canToggleTouchID)
        #expect(!viewModel.security.isBiometricsEnabled)
    }

    // MARK: - General and Advanced

    @Test func autoLockRejectsUnknownValues() async throws {
        let harness = try await TestHarness()
        let viewModel = PreferencesViewModel(app: harness.app)
        #expect(viewModel.autoLockMinutes == Timeouts.autoLockDefaultMinutes)
        viewModel.autoLockMinutes = 7
        #expect(viewModel.autoLockMinutes == Timeouts.autoLockDefaultMinutes)
        #expect(viewModel.autoLockOptions == Timeouts.autoLockOptionMinutes)
    }

    @Test func cloneFolderAndGHOverridePersist() async throws {
        let store = InMemoryPreferencesStore()
        let preferences = PreferencesManager(store: store)
        preferences.setCloneFolder(URL(fileURLWithPath: "/tmp/clones/../repos", isDirectory: true))
        preferences.ghPathOverride = "  /opt/homebrew/bin/gh  "
        let reloaded = PreferencesManager(store: store)
        #expect(reloaded.cloneFolderPath == "/tmp/repos")
        #expect(reloaded.ghPathOverride == "/opt/homebrew/bin/gh")
        reloaded.ghPathOverride = "   "
        #expect(reloaded.ghPathOverride == nil)
        #expect(PreferencesManager(store: store).ghPathOverride == nil)
    }

    /// 0.9's nearby name (personal data), visibility, mute and remote port go at the first launch.
    @Test func settingsOfTheRemovedFeaturesAreDeleted() {
        let store = InMemoryPreferencesStore()
        store.set("Ana's MacBook", forKey: "preferences.nearbyDisplayName")
        store.set("everyone", forKey: "preferences.nearbyVisibility")
        store.set(true, forKey: "preferences.mutesAllPings")
        store.set(7443, forKey: "preferences.remoteSpacePort")
        store.set(10, forKey: PreferencesManager.Key.autoLockMinutes)

        _ = PreferencesManager(store: store)

        #expect(store.string(forKey: "preferences.nearbyDisplayName") == nil)
        #expect(store.string(forKey: "preferences.nearbyVisibility") == nil)
        #expect(!store.bool(forKey: "preferences.mutesAllPings"))
        #expect(store.integer(forKey: "preferences.remoteSpacePort") == nil)
        #expect(store.integer(forKey: PreferencesManager.Key.autoLockMinutes) == 10)
    }

    @Test func resetVaultNeedsPasswordAndTypedWord() async throws {
        let harness = try await TestHarness(vault: .locked)
        let viewModel = PreferencesViewModel(app: harness.app)
        viewModel.beginResetVault()
        #expect(viewModel.isShowingResetVault)
        viewModel.resetPassword = otherTestPassword
        #expect(!viewModel.canResetVault)
        viewModel.resetConfirmationText = "Reset "
        #expect(viewModel.canResetVault)

        await viewModel.resetVault()
        #expect(viewModel.resetError == VaultError.wrongPassword.presentation)
        #expect(harness.vaultManager.state == .locked)

        viewModel.resetPassword = testPassword
        await viewModel.resetVault()
        #expect(viewModel.resetError == nil)
        #expect(!viewModel.isShowingResetVault)
        #expect(viewModel.resetPassword.isEmpty)
        #expect(harness.vaultManager.state == .noVault)
        #expect(harness.app.phase == .onboarding)
    }

    // MARK: - Security

    @Test func touchIDToggleAsksForThePassword() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let security = PreferencesViewModel(app: harness.app).security
        security.requestTouchID(enabled: true)
        #expect(security.activeSheet == .enableTouchID)

        security.currentPassword = otherTestPassword
        await security.confirmTouchIDChange()
        #expect(security.error == VaultError.wrongPassword.presentation)
        #expect(!security.isBiometricsEnabled)

        security.currentPassword = testPassword
        await security.confirmTouchIDChange()
        #expect(security.error == nil)
        #expect(security.isBiometricsEnabled)
        #expect(security.activeSheet == nil)
        #expect(security.currentPassword.isEmpty)

        security.requestTouchID(enabled: false)
        #expect(security.activeSheet == .disableTouchID)
        security.currentPassword = testPassword
        await security.confirmTouchIDChange()
        #expect(!security.isBiometricsEnabled)
        #expect(harness.biometrics.accounts.isEmpty)
    }

    @Test func unsignedBuildDisablesTheToggle() async throws {
        let harness = try await TestHarness(vault: .unlocked, signed: false)
        let security = PreferencesViewModel(app: harness.app).security
        #expect(security.biometricsUnavailableReason == .unsignedBuild)
        #expect(!security.canToggleTouchID)
        security.requestTouchID(enabled: true)
        #expect(security.activeSheet == nil)
    }

    @Test func changePasswordWithRotationShowsNewRecoveryKey() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let security = PreferencesViewModel(app: harness.app).security
        security.present(.changePassword)
        #expect(security.rotateVaultKey)
        security.currentPassword = testPassword
        security.newPassword = otherTestPassword
        security.newPasswordConfirmation = otherTestPassword
        #expect(security.canChangePassword)
        await security.changePassword()

        #expect(security.error == nil)
        #expect(security.activeSheet == .showRecoveryKey)
        #expect(security.recoveryKeyGroups.count == Limits.recoveryKeyGroupCount)
        #expect(security.newPassword.isEmpty)
        security.copyRecoveryKey()
        #expect(harness.pasteboardString == security.recoveryKeyGroups.joined(separator: "-"))
        security.acknowledgeRecoveryKey()
        #expect(security.activeSheet == nil)
        #expect(security.recoveryKeyGroups.isEmpty)

        harness.app.lock(trigger: .manual)
        try await harness.vaultManager.unlock(password: otherTestPassword)
    }

    @Test func changePasswordWithoutRotationClosesTheSheet() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let security = PreferencesViewModel(app: harness.app).security
        security.present(.changePassword)
        security.rotateVaultKey = false
        security.currentPassword = testPassword
        security.newPassword = otherTestPassword
        security.newPasswordConfirmation = otherTestPassword
        await security.changePassword()
        #expect(security.error == nil)
        #expect(security.activeSheet == nil)
        #expect(security.didChangePassword)
    }

    @Test func newRecoveryKeyNeedsThePassword() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let security = PreferencesViewModel(app: harness.app).security
        security.present(.newRecoveryKey)
        security.currentPassword = otherTestPassword
        await security.createNewRecoveryKey()
        #expect(security.error == VaultError.wrongPassword.presentation)
        #expect(security.activeSheet == .newRecoveryKey)

        security.currentPassword = testPassword
        await security.createNewRecoveryKey()
        #expect(security.activeSheet == .showRecoveryKey)
        #expect(security.recoveryKeyGroups.count == Limits.recoveryKeyGroupCount)
    }

    @Test func lockDismissesSheetsAndWipesKeys() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let viewModel = PreferencesViewModel(app: harness.app)
        let security = viewModel.security
        security.present(.newRecoveryKey)
        security.currentPassword = testPassword
        await security.createNewRecoveryKey()
        #expect(security.activeSheet == .showRecoveryKey)
        viewModel.beginResetVault()
        viewModel.resetPassword = "typed"

        harness.signals.send(.displaySleep)

        #expect(harness.app.phase == .locked)
        #expect(security.activeSheet == nil)
        #expect(security.recoveryKeyGroups.isEmpty)
        #expect(!viewModel.isShowingResetVault)
        #expect(viewModel.resetPassword.isEmpty)
        #expect(!viewModel.isVaultSettingsAvailable)
    }

    /// Settings › Advanced, In use: a ready gh shows its version and path; checking and unknown
    /// add nothing; every other state adds the status sentence under the row.
    @Test func theInUseRowFollowsTheGHStatus() {
        let ready = GHStatusModel.ready(version: "2.102.0", path: "/opt/homebrew/bin/gh")
        #expect(ready.inUse?.version == "2.102.0")
        #expect(ready.inUse?.path == "/opt/homebrew/bin/gh")
        #expect(!ready.needsInUseSentence)
        #expect(GHStatusModel.checking.inUse == nil)
        #expect(!GHStatusModel.checking.needsInUseSentence)
        #expect(!GHStatusModel.unknown.needsInUseSentence)
        #expect(GHStatusModel.notInstalled.needsInUseSentence)
        #expect(GHStatusModel.outdated(found: "2.40.0", required: "2.97.0", path: nil).needsInUseSentence)
        #expect(GHStatusModel.noAccounts(version: "2.102.0", path: "/opt/homebrew/bin/gh").needsInUseSentence)
        #expect(GHStatusModel.failed.needsInUseSentence)
    }
}
