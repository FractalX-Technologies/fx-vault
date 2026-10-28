import XCTest

/// The two-column main window (tasks/todo.md B11b, 1.0 D6c1): an organization's node opens to its
/// repositories, an imported repository's environments sit under its row, selecting one puts it
/// in the toolbar path, and the repository row goes back to the repository scope.
final class MainTreeUITests: VaultUITestCase {
    @MainActor
    func testEnvironmentsNestUnderTheRepositoryAndFollowTheToolbarPath() throws {
        let app = launch(appearance: .dark)
        let sidebar = mainSidebar(app)
        revealRepositories(of: "example-org", in: sidebar)
        let repository = sidebarRow("api-service", in: sidebar)
        click(repository)
        click(app.buttons[AccessibilityID.Main.importRepository])

        let staging = sidebar.buttons[AccessibilityID.Main.environment("staging")]
        XCTAssertTrue(staging.appears(within: timeout), "staging is not under api-service")
        XCTAssertTrue(sidebar.buttons[AccessibilityID.Main.environment("production")].exists)

        let path = app.staticTexts[AccessibilityID.Main.breadcrumb]
        XCTAssertTrue(path.appears(within: timeout))
        click(staging)
        expect(path, toEndWith: "api-service › staging")

        click(repository)
        expect(path, toEndWith: "api-service")

        // The open repository's chevron (the first row matching its name) went back to the
        // repository and hid its environments; it shows and hides them again.
        XCTAssertTrue(staging.disappears(within: timeout), "The chevron did not hide the environments")
        let toggle = sidebar.buttons[AccessibilityID.Main.repositoryToggle("api-service")]
        click(toggle)
        XCTAssertTrue(staging.appears(within: timeout), "The chevron did not show them again")
        click(toggle)
        XCTAssertTrue(staging.disappears(within: timeout), "The chevron did not hide them again")
        expect(path, toEndWith: "api-service")

        // Board Main2-Dark: the floating sidebar and the glass toolbar (JumpPaletteUITests has light).
        attachWindowScreenshot(of: app, named: "main-window-dark")
    }

    /// Subfolders (one level): New Folder… (⇧⌘N), then New Subfolder… from its menu twice; both
    /// sit under it, the new one opens, each shows its parent in the toolbar path, and the
    /// folder's chevron hides them.
    @MainActor
    func testSubfoldersSitUnderTheirFolderAndOpen() throws {
        let app = launch(appearance: .light)
        let sidebar = try onboard(app)

        app.typeKey("n", modifierFlags: [.shift, .command])
        createFolder(named: "Mobile", in: app)
        let mobile = sidebar.buttons[AccessibilityID.Main.folder("Mobile")]
        XCTAssertTrue(mobile.waitForExistence(timeout: timeout), "Mobile is not in the sidebar")

        let path = app.staticTexts[AccessibilityID.Main.breadcrumb]
        for name in ["Development", "Testflight Dev"] {
            mobile.rightClick()
            click(app.menuItems["New Subfolder…"])
            createFolder(named: name, in: app)
            expect(path, toEndWith: "Mobile › \(name)")
        }
        let development = sidebar.buttons[AccessibilityID.Main.folder("Mobile › Development")]
        let testflight = sidebar.buttons[AccessibilityID.Main.folder("Mobile › Testflight Dev")]
        XCTAssertTrue(development.waitForExistence(timeout: timeout), "Development is not under Mobile")
        XCTAssertTrue(testflight.exists, "Testflight Dev is not under Mobile")
        attachWindowScreenshot(of: app, named: "main-window-subfolders-light")

        click(development)
        expect(path, toEndWith: "Mobile › Development")

        click(sidebar.buttons[AccessibilityID.Main.folderToggle("Mobile")])
        XCTAssertTrue(testflight.waitForNonExistence(timeout: timeout), "The chevron did not hide the subfolders")
    }

    @MainActor
    private func createFolder(named name: String, in app: XCUIApplication) {
        let field = app.textFields[AccessibilityID.Main.folderName]
        type(name, into: field)
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: timeout), "The folder sheet did not close")
    }
}
