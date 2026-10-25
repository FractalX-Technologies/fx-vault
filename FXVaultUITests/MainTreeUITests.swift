import XCTest

/// The two-column main window (tasks/todo.md B11b): an imported repository's environments sit
/// under its sidebar row, selecting one puts it in the toolbar path, and the repository row goes
/// back to the repository scope.
final class MainTreeUITests: VaultUITestCase {
    @MainActor
    func testEnvironmentsNestUnderTheRepositoryAndFollowTheToolbarPath() throws {
        let app = launch()
        let sidebar = try onboard(app)
        let repository = sidebarRow("api-service", in: sidebar)
        click(repository)
        click(app.buttons[AccessibilityID.Main.importRepository])

        let staging = sidebar.buttons[AccessibilityID.Main.environment("staging")]
        XCTAssertTrue(staging.waitForExistence(timeout: timeout), "staging is not under api-service")
        XCTAssertTrue(sidebar.buttons[AccessibilityID.Main.environment("production")].exists)

        let path = app.staticTexts[AccessibilityID.Main.breadcrumb]
        XCTAssertTrue(path.waitForExistence(timeout: timeout))
        click(staging)
        expect(path, toEndWith: "api-service › staging")

        click(repository)
        expect(path, toEndWith: "api-service")
    }

    @MainActor
    private func expect(_ path: XCUIElement, toEndWith suffix: String) {
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label ENDSWITH %@ OR value ENDSWITH %@", suffix, suffix),
            object: path
        )
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: timeout), .completed, "The path never ended with \(suffix)")
    }
}
