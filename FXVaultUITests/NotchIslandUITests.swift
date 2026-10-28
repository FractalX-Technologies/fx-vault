import XCTest

/// The notch island replaces the lock window (tasks/todo.md B11e): locking closes the main
/// window and shows nothing; opening FX Vault shows the island, and the master password there
/// unlocks and the window comes back.
/// UI-testing builds are ad-hoc signed, so Touch ID is unavailable and the island asks for the
/// password at once.
final class NotchIslandUITests: VaultUITestCase {
    @MainActor
    func testLockingHidesEverythingAndTheIslandsPasswordUnlocks() throws {
        let app = launch()
        let sidebar = mainSidebar(app)

        lockThenOpenIsland(app)
        let field = app.secureTextFields[AccessibilityID.Island.password]
        XCTAssertTrue(field.appears(within: timeout), "The island never asked for the password")
        XCTAssertTrue(sidebar.disappears(within: timeout), "The main window stayed open while locked")
        XCTAssertFalse(app.staticTexts["api-service"].exists, "The island shows a name")

        type(password, into: field)
        field.typeKey(.return, modifierFlags: [])
        _ = mainSidebar(app)
    }
}
