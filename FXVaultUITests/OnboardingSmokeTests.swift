import XCTest

/// The smoke flow (tasks/todo.md B0): onboarding to a main window listing the scripted org, and
/// ⌘F finding its repository (1.0).
final class OnboardingSmokeTests: VaultUITestCase {
    @MainActor
    func testOnboardingReachesTheMainWindow() throws {
        let app = launch()
        let sidebar = try onboard(app)
        for name in ["owner-a", "example-org"] {
            XCTAssertTrue(sidebarRow(name, in: sidebar).waitForExistence(timeout: timeout), "\(name) is not in the sidebar")
        }
        XCTAssertFalse(sidebar.descendants(matching: .any)["Could not be listed"].exists)
        expectTrafficLightsInTheSidebarPanel(of: app)

        // 1.0: the owners start collapsed; ⌘F searches the tree and opens the owner of a match.
        searchSidebar(for: "api-service", in: app)
        XCTAssertTrue(sidebarRow("api-service", in: sidebar).waitForExistence(timeout: timeout), "api-service is not found")

        // Edit › Find brings a hidden sidebar (View › Hide Sidebar, ⌃⌘S) back before it focuses
        // the search field.
        app.textFields[AccessibilityID.Main.sidebarSearch].typeKey(.escape, modifierFlags: [])
        app.typeKey("s", modifierFlags: [.control, .command])
        searchHiddenSidebar(for: "example", in: app)
    }

    /// Board Main2-Home (1.0 D6c2b): the traffic lights sit about 19 pt in from the window's top
    /// leading corner, inside the sidebar panel, and above its search field.
    @MainActor
    private func expectTrafficLightsInTheSidebarPanel(of app: XCUIApplication) {
        let window = app.windows.firstMatch
        let close = window.buttons[XCUIIdentifierCloseWindow]
        let search = app.textFields[AccessibilityID.Main.sidebarSearch]
        XCTAssertTrue(close.waitForExistence(timeout: timeout), "The window has no close button")
        XCTAssertTrue(search.waitForExistence(timeout: timeout), "The sidebar has no search field")
        XCTAssertEqual(close.frame.minX - window.frame.minX, 19, accuracy: 2, "The traffic lights moved sideways")
        XCTAssertEqual(close.frame.minY - window.frame.minY, 19, accuracy: 2, "The traffic lights moved down or up")
        XCTAssertLessThan(close.frame.maxY, search.frame.minY, "The traffic lights overlap the search field")
        XCTAssertTrue(close.isHittable, "The close button is covered")
    }
}
