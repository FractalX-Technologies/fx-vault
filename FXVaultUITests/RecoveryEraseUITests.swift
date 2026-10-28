import XCTest

/// The last resort when both the master password and the recovery key are lost: from the
/// island's Recovery Key…, erase the vault by typing the confirmation word, and FX Vault starts
/// over at onboarding.
final class RecoveryEraseUITests: VaultUITestCase {
    @MainActor
    func testWithNeitherPasswordNorKeyTheVaultIsErasedAndOnboardingReturns() throws {
        let app = launch()
        mainSidebar(app)

        lockThenOpenIsland(app)
        let recovery = app.buttons[AccessibilityID.Island.recoveryKey]
        XCTAssertTrue(recovery.appears(within: timeout), "The island never showed")
        click(recovery)

        click(app.buttons[AccessibilityID.Recovery.forgotKey])
        let erase = app.buttons[AccessibilityID.Recovery.erase]
        XCTAssertTrue(erase.appears(within: timeout))
        XCTAssertFalse(erase.isEnabled, "Erase waits for the confirmation word")
        type("reset", into: app.textFields[AccessibilityID.Recovery.eraseConfirmation])
        click(erase)

        XCTAssertTrue(
            app.buttons[AccessibilityID.Onboarding.createVault].appears(within: timeout),
            "After the erase FX Vault must offer a new vault"
        )
    }
}
