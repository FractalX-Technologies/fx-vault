import Foundation
import SwiftUI
import Testing
@testable import FXVault

/// Presentation helpers of the main window (v0.3.0 FractalX restyle): keyboard selection in the
/// custom-drawn sidebar and scope columns, sidebar avatars, the table's timestamp and titles.
@MainActor
@Suite("Main screen presentation")
struct MainScreenPresentationTests {
    // MARK: - Column keyboard selection

    @Test func downAndUpWalkTheColumnInOrder() {
        let ids = ["a", "b", "c"]
        #expect(MainColumnSelection.id(after: "a", in: ids, direction: .down) == "b")
        #expect(MainColumnSelection.id(after: "b", in: ids, direction: .down) == "c")
        #expect(MainColumnSelection.id(after: "c", in: ids, direction: .up) == "b")
        #expect(MainColumnSelection.id(after: "b", in: ids, direction: .up) == "a")
    }

    @Test func selectionStopsAtTheEnds() {
        let ids = ["a", "b"]
        #expect(MainColumnSelection.id(after: "a", in: ids, direction: .up) == nil)
        #expect(MainColumnSelection.id(after: "b", in: ids, direction: .down) == nil)
    }

    @Test func withoutSelectionDownPicksFirstAndUpPicksLast() {
        let ids = ["a", "b", "c"]
        #expect(MainColumnSelection.id(after: nil, in: ids, direction: .down) == "a")
        #expect(MainColumnSelection.id(after: nil, in: ids, direction: .up) == "c")
        // A selection that is not visible (collapsed group, filtered out) behaves like none.
        #expect(MainColumnSelection.id(after: "hidden", in: ids, direction: .down) == "a")
    }

    @Test func leftRightAndEmptyColumnsKeepTheSelection() {
        #expect(MainColumnSelection.id(after: "a", in: ["a", "b"], direction: .left) == nil)
        #expect(MainColumnSelection.id(after: "a", in: ["a", "b"], direction: .right) == nil)
        #expect(MainColumnSelection.id(after: nil, in: [String](), direction: .down) == nil)
    }

    // MARK: - Sidebar avatar

    @Test func avatarInitialsUseTheFirstTwoWords() {
        #expect(SidebarAccountModel.initials(of: "user-a") == "UA")
        #expect(SidebarAccountModel.initials(of: "example_org.dev") == "EO")
        #expect(SidebarAccountModel.initials(of: "octocat") == "OC")
        #expect(SidebarAccountModel.initials(of: "x") == "X")
        #expect(SidebarAccountModel.initials(of: "") == "")
    }

    // MARK: - Table

    @Test func updatedTextOmitsTheCurrentYear() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12)))
        let sameYear = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 9, minute: 5)))
        let lastYear = try #require(calendar.date(from: DateComponents(year: 2025, month: 3, day: 2, hour: 9, minute: 5)))
        let current = ConfigTableView.updatedText(sameYear, now: now, calendar: calendar)
        let older = ConfigTableView.updatedText(lastYear, now: now, calendar: calendar)
        #expect(current.contains("·"))
        #expect(!current.contains("2026"))
        #expect(older.contains("2025"))
        #expect(!older.contains("·"), "only the date outside the current year")
    }

    @Test func columnTitlesRender() {
        #expect(ImageRenderer(content: ConfigTableView.header("Updated")).nsImage != nil)
    }

    // MARK: - Rendering

    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func connectivityBannersRender(scheme: ColorScheme) {
        for banner in [ConnectivityBannerModel.offline, .gitHubNotResponding(isRetrying: false), .gitHubNotResponding(isRetrying: true)] {
            let view = ConnectivityBannerView(banner: banner) {}
                .frame(width: Theme.Layout.detailMinWidth)
                .environment(\.colorScheme, scheme)
            #expect(ImageRenderer(content: view).nsImage != nil)
        }
    }

    @Test(arguments: [ColorScheme.light, ColorScheme.dark])
    func maskedValueCellsRender(scheme: ColorScheme) {
        let displays: [ConfigValueDisplayModel] = [.masked, .revealed("value"), .plain("value"), .missing]
        for display in displays {
            let view = MaskedValueCell(display: display) {}
                .environment(\.colorScheme, scheme)
            #expect(ImageRenderer(content: view).nsImage != nil)
        }
    }
}
