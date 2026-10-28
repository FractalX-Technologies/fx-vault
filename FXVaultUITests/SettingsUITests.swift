import XCTest

/// Settings in the main window (boards Settings-General, Settings-Accounts, Settings-Security):
/// the quick vault shortcut records a new key, Add Account… gives gh's login command, Reset vault
/// sits on the Security section, Search Settings filters the sections and Back returns to the vault.
final class SettingsUITests: VaultUITestCase {
    @MainActor
    func testTheQuickVaultShortcutRecordsANewKey() throws {
        let app = launch()
        mainSidebar(app)
        app.typeKey(",", modifierFlags: .command)

        let recorder = app.descendants(matching: .any)[AccessibilityID.Settings.quickVaultShortcut]
        XCTAssertTrue(recorder.appears(within: timeout))
        expect(recorder, toRead: "Control-Option-V")
        click(recorder)
        app.typeKey("k", modifierFlags: [.control, .option])
        expect(recorder, toRead: "Control-Option-K")
    }

    @MainActor
    func testAddAccountGivesTheLoginCommand() throws {
        let app = launch()
        mainSidebar(app)
        app.typeKey(",", modifierFlags: .command)
        click(app.buttons[AccessibilityID.Settings.section("accounts")])

        click(app.buttons[AccessibilityID.Accounts.addAccount])
        let command = app.staticTexts[AccessibilityID.Setup.command("gh auth login")].firstMatch
        XCTAssertTrue(command.appears(within: timeout))
        let checkAgain = app.buttons[AccessibilityID.Accounts.addAccountCheckAgain]
        click(checkAgain)
        XCTAssertTrue(checkAgain.disappears(within: timeout), "Check Again closes the popover")
    }

    @MainActor
    func testResetVaultIsOnTheSecurityTab() throws {
        let app = launch()
        mainSidebar(app)
        app.typeKey(",", modifierFlags: .command)
        click(app.buttons[AccessibilityID.Settings.section("security")])
        let reset = app.buttons[AccessibilityID.Settings.resetVault]
        XCTAssertTrue(reset.appears(within: timeout))

        click(app.buttons[AccessibilityID.Settings.section("advanced")])
        XCTAssertTrue(app.buttons[AccessibilityID.Settings.revealVaultFolder].appears(within: timeout))
        XCTAssertFalse(reset.exists, "Reset vault left Advanced")
    }

    @MainActor
    func testSearchSettingsAndBackReturnToTheVault() throws {
        let app = launch()
        mainSidebar(app)
        click(app.buttons[AccessibilityID.Settings.open])

        let search = app.textFields[AccessibilityID.Settings.search]
        XCTAssertTrue(search.appears(within: timeout))
        click(search)
        search.typeText("touch id")
        let general = app.buttons[AccessibilityID.Settings.section("general")]
        XCTAssertTrue(general.disappears(within: timeout), "General has no Touch ID")
        XCTAssertTrue(app.buttons[AccessibilityID.Settings.section("security")].exists)

        click(app.buttons[AccessibilityID.Settings.back])
        XCTAssertTrue(app.descendants(matching: .any)[AccessibilityID.Main.sidebar].appears(within: timeout))
        XCTAssertFalse(search.exists, "Back left Settings")
    }

    /// A button reports its accessibility value as its value on macOS, sometimes in its label.
    @MainActor
    private func expect(_ element: XCUIElement, toRead text: String) {
        let reads = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        XCTAssertTrue(element.satisfies(reads, within: timeout), "\(element) never read \(text)")
    }
}
