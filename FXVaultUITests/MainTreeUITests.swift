import XCTest

/// The two-column main window (tasks/todo.md B11b, 1.0 D6c1): an organization's node opens to its
/// repositories, an imported repository's environments sit under its row, selecting one puts it
/// in the toolbar path, and the repository row goes back to the repository scope.
final class MainTreeUITests: VaultUITestCase {
    @MainActor
    func testEnvironmentsNestUnderTheRepositoryAndFollowTheToolbarPath() throws {
        let app = launch(appearance: .dark)
        let sidebar = try onboard(app)
        revealRepositories(of: "example-org", in: sidebar)
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

        // Board Main2-Dark: the floating sidebar and the glass toolbar (JumpPaletteUITests has light).
        attachWindowScreenshot(of: app, named: "main-window-dark")
    }
}
