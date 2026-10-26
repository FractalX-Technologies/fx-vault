import XCTest

/// The ⌘K jump palette (1.0 D6c2, D6c5; board Main2-Search): typing filters the places, ↓ moves
/// and ↩ opens the selected one in the toolbar path; a name opens its place; esc closes.
final class JumpPaletteUITests: VaultUITestCase {
    @MainActor
    func testTypingFiltersAndReturnOpensThePlace() throws {
        let app = launch(appearance: .light)
        let sidebar = try onboard(app)
        // Board Main2-Home: the home, the toolbar's search button and Sync.
        XCTAssertTrue(app.buttons[AccessibilityID.Main.jumpAnywhere].waitForExistence(timeout: timeout))
        attachWindowScreenshot(of: app, named: "main-window-home-light")

        revealRepositories(of: "example-org", in: sidebar)
        click(sidebarRow("api-service", in: sidebar))
        click(app.buttons[AccessibilityID.Main.importRepository])
        XCTAssertTrue(sidebar.buttons[AccessibilityID.Main.environment("staging")].waitForExistence(timeout: timeout))
        let path = app.staticTexts[AccessibilityID.Main.breadcrumb]
        expect(path, toEndWith: "example-org › api-service")

        // esc closes without opening anything.
        let field = app.textFields[AccessibilityID.Jump.field]
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "⌘K did not open the palette")
        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: timeout), "esc did not close the palette")

        // "api": the repository by its name first, then its environments by their path.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "⌘K did not open the palette")
        app.typeText("api")
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "api"), object: field)
        XCTAssertEqual(XCTWaiter().wait(for: [typed], timeout: timeout), .completed, "The palette's field did not take the typing")
        attachWindowScreenshot(of: app, named: "main-window-jump-light")
        field.typeKey(.downArrow, modifierFlags: [])
        field.typeKey(.return, modifierFlags: [])

        expect(path, toEndWith: "api-service › production")
        XCTAssertTrue(field.waitForNonExistence(timeout: timeout), "↩ did not close the palette")
        attachWindowScreenshot(of: app, named: "main-window-light")

        // "Secrets by name" (1.0 D6c5): staging's MODE variable, by name only; ↩ opens staging.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "⌘K did not open the palette")
        app.typeText("mode")
        XCTAssertTrue(app.staticTexts["Secrets by name"].waitForExistence(timeout: timeout), "No names section")
        field.typeKey(.return, modifierFlags: [])
        expect(path, toEndWith: "api-service › staging")
        XCTAssertTrue(field.waitForNonExistence(timeout: timeout), "↩ did not close the palette")
    }
}
