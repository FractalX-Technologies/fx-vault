import XCTest

/// Add file secret (tasks/todo.md F1; board Place-FileSheet): ⋯ More › Add File Secret… on an
/// imported repository, Choose… (the UITesting host picks its own synthetic file instead of an
/// open panel), the name the file suggests, then Add: the table shows the file for the value.
final class FileSecretUITests: VaultUITestCase {
    @MainActor
    func testAddingAFileSecretShowsTheFileInPlaceOfTheValue() throws {
        let app = launch()
        let sidebar = try onboard(app)
        revealRepositories(of: "example-org", in: sidebar)
        click(sidebarRow("api-service", in: sidebar))
        click(app.buttons[AccessibilityID.Main.importRepository])
        let notes = app.descendants(matching: .any)[AccessibilityID.Place.notes]
        XCTAssertTrue(notes.waitForExistence(timeout: timeout), "The import never showed the notes")

        click(app.descendants(matching: .any).matching(identifier: AccessibilityID.Place.more).firstMatch)
        // By title: a SwiftUI menu item's identifier is "menuAction:", never the button's.
        click(app.menuItems["Add File Secret…"])
        let add = app.buttons[AccessibilityID.FileSecret.add]
        XCTAssertTrue(add.waitForExistence(timeout: timeout), "Add File Secret… opened no sheet")
        XCTAssertFalse(add.isEnabled, "Add waits for a file")

        click(app.buttons[AccessibilityID.FileSecret.choose])
        let name = app.textFields[AccessibilityID.FileSecret.name]
        let suggested = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "AUTH_KEY_P8"), object: name)
        XCTAssertEqual(XCTWaiter().wait(for: [suggested], timeout: timeout), .completed, "The file suggested no name")
        let limits = app.descendants(matching: .any)[AccessibilityID.FileSecret.limits]
        XCTAssertTrue(limits.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["AuthKey_FIXTURE01.p8"].exists, "The file row does not name the file")
        click(add)
        XCTAssertTrue(add.waitForNonExistence(timeout: timeout), "Add did not close the sheet")

        click(app.descendants(matching: .any)[AccessibilityID.Place.viewMode].buttons["Table"])
        let chip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "From the file AuthKey_FIXTURE01.p8, 3 lines"))
            .firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: timeout), "The table does not show the file for the value")
        XCTAssertTrue(app.staticTexts["AUTH_KEY_P8"].exists)
    }
}
