import AppKit
import SwiftUI
import Testing
@testable import FXVault

/// Layout of the main window's panels: content never pushes another panel, the traffic lights
/// or the window edges.
@MainActor
@Suite("Main window layout")
struct MainWindowLayoutTests {
    /// With nothing selected, the sidebar and the detail show empty states whose messages wrap.
    /// A column's minimum height is measured at zero width (about 1,000 pt for a wrapped
    /// message): as the window's minimum it grew the window, and the split view before D6c2b
    /// overflowed it (the sidebar under the traffic lights, its footer below the window).
    @Test func emptyColumnsKeepTheWindowHeight() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let main = harness.app.makeMainViewModel()
        #expect(main.selectedRepo == nil)
        let window = Self.window(showing: MainScreen(viewModel: main), contentSize: Self.defaultSize)
        defer { window.close() }

        #expect(window.frame.height == Self.defaultSize.height)
        #expect(Self.subviews(of: window).allSatisfy { $0.frame.height <= Self.defaultSize.height })
    }

    /// Board Main2-Home: the title bar is hidden and its empty toolbar makes AppKit put the
    /// traffic lights 19 pt in, inside the sidebar panel's top inset: past the panel's corner,
    /// above its search field, and before the toolbar panel when the sidebar is hidden.
    @Test func trafficLightsSitInTheSidebarPanel() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let main = harness.app.makeMainViewModel()
        let window = Self.window(showing: MainScreen(viewModel: main), contentSize: Self.defaultSize)
        defer { window.close() }
        #expect(await TestFixtures.eventually { window.toolbar?.identifier == MainWindowTitleBar.toolbarIdentifier })
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        window.layoutIfNeeded()

        let close = try Self.topLeadingFrame(of: .closeButton, in: window)
        let zoom = try Self.topLeadingFrame(of: .zoomButton, in: window)
        #expect(close.minX >= Theme.Layout.mainPanelInset + Theme.Spacing.small, "inside the panel's corner")
        #expect(close.minY >= Theme.Layout.mainPanelInset + Theme.Spacing.small, "inside the panel's corner")
        #expect(zoom.maxY <= Theme.Layout.mainPanelInset + Theme.Layout.sidebarPanelTopInset, "over the search field")
        #expect(zoom.maxX <= Theme.Layout.trafficLightsWidth, "under the toolbar panel with the sidebar hidden")
    }

    /// Locking replaces the main screen: its empty toolbar and hidden title go with it, so the
    /// lock screen gets the window's own title bar back.
    @Test func theTitleBarGoesWithTheMainScreen() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let main = harness.app.makeMainViewModel()
        let controller = NSHostingController(rootView: AnyView(MainScreen(viewModel: main).fxWindowBackground()))
        let window = Self.window(controller: controller, contentSize: Self.defaultSize)
        defer { window.close() }
        #expect(await TestFixtures.eventually { window.toolbar != nil })

        controller.rootView = AnyView(Text(verbatim: "Locked"))
        #expect(await TestFixtures.eventually { window.toolbar == nil })
        #expect(!window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .visible)
    }

    /// SwiftUI can show the next main screen before the last one disappears: the first one out
    /// keeps the title bar for the second, and the last one out restores the window's own.
    @Test func overlappingMainScreensKeepTheTitleBarUntilTheLastLeaves() {
        let window = Self.window(showing: Text(verbatim: "Locked"), contentSize: Self.defaultSize)
        defer { window.close() }
        let first = MainWindowTitleBar()
        let second = MainWindowTitleBar()
        first.install(in: window)
        second.install(in: window)

        first.remove()
        #expect(window.toolbar?.identifier == MainWindowTitleBar.toolbarIdentifier)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)

        second.remove()
        #expect(window.toolbar == nil)
        #expect(window.titleVisibility == .visible)
        #expect(!window.titlebarAppearsTransparent)
    }

    /// An update that clears the window's toolbar gets the empty one back at once, or the traffic
    /// lights would drop to the title bar's corner, over the sidebar panel's edge.
    @Test func theToolbarComesBackWhenSomethingClearsIt() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let main = harness.app.makeMainViewModel()
        let window = Self.window(showing: MainScreen(viewModel: main), contentSize: Self.defaultSize)
        defer { window.close() }
        #expect(await TestFixtures.eventually { window.toolbar?.identifier == MainWindowTitleBar.toolbarIdentifier })

        window.toolbar = nil
        #expect(window.toolbar?.identifier == MainWindowTitleBar.toolbarIdentifier)
    }

    /// The main screen's minimum is the same with the sidebar hidden: a window narrowed then would
    /// push the detail past its edge when ⌃⌘S shows the sidebar again (it measured 436 pt).
    @Test func hidingTheSidebarKeepsTheMinimumWidth() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let main = harness.app.makeMainViewModel()
        let shown = NSHostingController(rootView: MainScreen(viewModel: main)).sizeThatFits(in: .zero).width
        main.toggleSidebar()
        #expect(main.isSidebarHidden)
        let hidden = NSHostingController(rootView: MainScreen(viewModel: main)).sizeThatFits(in: .zero).width
        #expect(hidden == shown)
        #expect(hidden >= 3 * Theme.Layout.mainPanelInset + Theme.Layout.sidebarMaxWidth + Theme.Layout.detailMinWidth)
        withExtendedLifetime(harness) {}
    }

    /// The gutters are window chrome; the detail's empty parts (around the home's empty state,
    /// beside a title) take their own clicks, so they never drag or zoom the window.
    @Test func onlyTheChromeMovesTheWindow() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let main = harness.app.makeMainViewModel()
        let window = Self.window(showing: MainScreen(viewModel: main), contentSize: Self.defaultSize)
        defer { window.close() }
        #expect(await TestFixtures.eventually { window.toolbar?.identifier == MainWindowTitleBar.toolbarIdentifier })
        window.layoutIfNeeded()
        let inset = Theme.Layout.mainPanelInset

        // The gutter under the detail (window points start at the bottom); the sidebar is flush
        // with the leading edge since 1.0.2.
        let detailLeading = Theme.Layout.sidebarWidth + inset
        let gutter = CGPoint(x: detailLeading + Theme.Spacing.large, y: inset / 2)
        #expect(Self.view(at: gutter, in: window) is WindowDragArea.DragAreaView)
        // The detail's bottom leading corner.
        let detailCorner = CGPoint(x: detailLeading + Theme.Spacing.large, y: inset + Theme.Spacing.large)
        #expect(!(Self.view(at: detailCorner, in: window) is WindowDragArea.DragAreaView))
        withExtendedLifetime(harness) {}
    }

    /// A double-click on the window's chrome does what System Settings › Desktop & Dock says.
    @Test func aDoubleClickOnTheChromeFollowsSystemSettings() {
        typealias Action = TitleBarDoubleClickAction
        #expect(Action.resolve(actionOnDoubleClick: nil, minimizesOnDoubleClick: false) == .zoom)
        #expect(Action.resolve(actionOnDoubleClick: "Fill", minimizesOnDoubleClick: false) == .zoom)
        #expect(Action.resolve(actionOnDoubleClick: "Maximize", minimizesOnDoubleClick: true) == .zoom)
        #expect(Action.resolve(actionOnDoubleClick: "Minimize", minimizesOnDoubleClick: false) == .minimize)
        #expect(Action.resolve(actionOnDoubleClick: "None", minimizesOnDoubleClick: false) == .none)
        #expect(Action.resolve(actionOnDoubleClick: nil, minimizesOnDoubleClick: true) == .minimize)
    }

    /// The detail (header, Secrets | Variables pill and add actions, table) fits the narrowest
    /// detail column: rows that do not fit wrap below, and the table scrolls, instead of spilling
    /// under the scope column and past the window edge.
    @Test func detailFitsItsNarrowestColumn() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        let detail = try #require(main.detail)
        let controller = NSHostingController(rootView: RepoDetailScreen(viewModel: detail, main: main).fxWindowBackground())
        #expect(controller.sizeThatFits(in: .zero).width <= Theme.Layout.detailMinWidth)
        withExtendedLifetime(harness) {}
    }

    /// A folder's detail (v0.7.0) fits the narrowest detail column too, and its main window keeps
    /// the window height with FOLDERS in the sidebar.
    @Test func folderDetailFitsItsNarrowestColumn() async throws {
        let (harness, main) = try await MainSnapshotFixture.make()
        main.sidebar.selectedFolderID = try MainSnapshotFixture.mobileFolder(harness, main)
        let folder = try #require(main.folderDetail)
        #expect(await TestFixtures.eventually { folder.items.count == 3 })
        let controller = NSHostingController(rootView: FolderDetailScreen(viewModel: folder, main: main).fxWindowBackground())
        #expect(controller.sizeThatFits(in: .zero).width <= Theme.Layout.detailMinWidth)

        let window = Self.window(showing: MainScreen(viewModel: main), contentSize: Self.defaultSize)
        defer { window.close() }
        #expect(window.frame.height == Self.defaultSize.height)
        withExtendedLifetime(harness) {}
    }

    private static let defaultSize = CGSize(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)

    /// An offscreen titled window (full-size content, like the app's main window) laid out at
    /// `contentSize`.
    private static func window(showing view: some View, contentSize: CGSize) -> NSWindow {
        window(controller: NSHostingController(rootView: view.fxWindowBackground()), contentSize: contentSize)
    }

    private static func window(controller: NSViewController, contentSize: CGSize) -> NSWindow {
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.setContentSize(contentSize)
        window.layoutIfNeeded()
        return window
    }

    /// The view a click at `point` (window coordinates) lands on.
    private static func view(at point: CGPoint, in window: NSWindow) -> NSView? {
        guard let content = window.contentView, let frame = content.superview else { return nil }
        return content.hitTest(frame.convert(point, from: nil))
    }

    /// A title bar button's frame from the window's top leading corner.
    private static func topLeadingFrame(of type: NSWindow.ButtonType, in window: NSWindow) throws -> CGRect {
        let button = try #require(window.standardWindowButton(type))
        let frame = button.convert(button.bounds, to: nil)
        return CGRect(x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func subviews(of window: NSWindow) -> [NSView] {
        guard let root = window.contentView else { return [] }
        var views: [NSView] = []
        var pending = [root]
        while let view = pending.popLast() {
            views.append(view)
            pending.append(contentsOf: view.subviews)
        }
        return views
    }

    /// A path too wide for the toolbar drops its first steps down to the last one (B8b3: "Azure
    /// Key Vault › name" fell straight back to the app name beside the DEV chip).
    @Test func toolbarPathFallsBackStepByStep() {
        #expect(MainToolbarTitle.fallbacks(["Azure Key Vault", "kv-example-prod"]) == [
            ["Azure Key Vault", "kv-example-prod"], ["kv-example-prod"], [],
        ])
        #expect(MainToolbarTitle.fallbacks(["GitHub", "owner", "repo"]).map(\.count) == [3, 2, 1, 0])
        #expect(MainToolbarTitle.fallbacks([]) == [[]])
    }
}
