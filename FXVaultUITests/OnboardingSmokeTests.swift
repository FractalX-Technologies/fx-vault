import XCTest

/// The smoke flow (tasks/todo.md B0): onboarding to a main window listing the scripted org.
final class OnboardingSmokeTests: VaultUITestCase {
    @MainActor
    func testOnboardingReachesTheMainWindow() throws {
        let app = launch()
        let sidebar = try onboard(app)
        for name in ["owner-a", "example-org", "api-service"] {
            XCTAssertTrue(sidebarRow(name, in: sidebar).waitForExistence(timeout: timeout), "\(name) is not in the sidebar")
        }
        XCTAssertFalse(sidebar.descendants(matching: .any)["Could not be listed"].exists)
    }
}
