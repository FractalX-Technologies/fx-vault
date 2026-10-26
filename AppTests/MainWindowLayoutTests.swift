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
