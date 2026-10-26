import XCTest

/// Settings as the boards (Settings-General, Settings-Accounts, Settings-Security): the quick
/// vault shortcut records a new key, Add Account… gives gh's login command, and Reset vault sits
/// on the Security tab.
final class SettingsUITests: VaultUITestCase {
    @MainActor
    func testTheQuickVaultShortcutRecordsANewKey() throws {
        let app = launch()
        try onboard(app)
        app.typeKey(",", modifierFlags: .command)

        let recorder = app.descendants(matching: .any)[AccessibilityID.Settings.quickVaultShortcut]
        XCTAssertTrue(recorder.waitForExistence(timeout: timeout))
        expect(recorder, toRead: "Control-Option-V")
        click(recorder)
        app.typeKey("k", modifierFlags: [.control, .option])
        expect(recorder, toRead: "Control-Option-K")
    }

    @MainActor
    func testAddAccountGivesTheLoginCommand() throws {
        let app = launch()
        try onboard(app)
        app.typeKey(",", modifierFlags: .command)
        click(app.toolbars.buttons["Accounts"])

        click(app.buttons[AccessibilityID.Accounts.addAccount])
        let command = app.staticTexts[AccessibilityID.Setup.command("gh auth login")].firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: timeout))
        let checkAgain = app.buttons[AccessibilityID.Accounts.addAccountCheckAgain]
        click(checkAgain)
        XCTAssertTrue(checkAgain.waitForNonExistence(timeout: timeout), "Check Again closes the popover")
    }

    @MainActor
    func testResetVaultIsOnTheSecurityTab() throws {
        let app = launch()
        try onboard(app)
        app.typeKey(",", modifierFlags: .command)
        click(app.toolbars.buttons["Security"])
        let reset = app.buttons[AccessibilityID.Settings.resetVault]
        XCTAssertTrue(reset.waitForExistence(timeout: timeout))

        click(app.toolbars.buttons["Advanced"])
        XCTAssertTrue(app.buttons[AccessibilityID.Settings.revealVaultFolder].waitForExistence(timeout: timeout))
        XCTAssertFalse(reset.exists, "Reset vault left Advanced")
    }

    /// A button reports its accessibility value as its value on macOS, sometimes in its label.
    @MainActor
    private func expect(_ element: XCUIElement, toRead text: String) {
        let reads = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text),
            object: element
        )
        XCTAssertEqual(XCTWaiter().wait(for: [reads], timeout: timeout), .completed, "\(element) never read \(text)")
    }
}
