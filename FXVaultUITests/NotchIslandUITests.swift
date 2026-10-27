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
        let sidebar = try onboard(app)

        lockThenOpenIsland(app)
        let field = app.secureTextFields[AccessibilityID.Island.password]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "The island never asked for the password")
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sidebar)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: timeout), .completed, "The main window stayed open while locked")
        XCTAssertFalse(app.staticTexts["api-service"].exists, "The island shows a name")

        type(password, into: field)
        field.typeKey(.return, modifierFlags: [])
        _ = mainSidebar(app)
    }
}
