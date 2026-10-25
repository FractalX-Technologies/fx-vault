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

        // 1.0: the owners start collapsed; ⌘F searches the tree and opens the owner of a match.
        searchSidebar(for: "api-service", in: app)
        XCTAssertTrue(sidebarRow("api-service", in: sidebar).waitForExistence(timeout: timeout), "api-service is not found")

        // Edit › Find brings a hidden sidebar (View › Hide Sidebar, ⌃⌘S) back before it focuses
        // the search field.
        app.textFields[AccessibilityID.Main.sidebarSearch].typeKey(.escape, modifierFlags: [])
        app.typeKey("s", modifierFlags: [.control, .command])
        searchHiddenSidebar(for: "example", in: app)
    }
}
