import AppKit
import SwiftUI
import Testing
@testable import FXVault

/// Layout of the main window's columns: content never pushes another column, the title
/// bar or the window edges.
@MainActor
@Suite("Main window layout")
struct MainWindowLayoutTests {
    /// With nothing selected, the sidebar, scope and detail columns show empty states whose
    /// messages wrap. AppKit sizes the split view from each column's minimum height, measured at
    /// zero width (about 1,000 pt for a wrapped message): the window grew, or in the app's own
    /// window the split view overflowed it, so the sidebar slid under the traffic lights and its
    /// footer dropped below the window.
    @Test func emptyColumnsKeepTheWindowHeight() async throws {
        let harness = try await TestHarness(vault: .unlocked)
        let main = harness.app.makeMainViewModel()
        #expect(main.selectedRepo == nil)
        let size = CGSize(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
        let window = Self.window(showing: MainScreen(viewModel: main), contentSize: size)
        defer { window.close() }

        #expect(window.frame.height == size.height)
        let splitViews = Self.subviews(of: window).compactMap { $0 as? NSSplitView }
        #expect(!splitViews.isEmpty)
        for splitView in splitViews {
            #expect(splitView.frame.height <= size.height)
        }
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

    /// An offscreen titled window (full-size content, like the app's main window) laid out at
    /// `contentSize`.
    private static func window(showing view: some View, contentSize: CGSize) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view.fxWindowBackground()))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.setContentSize(contentSize)
        window.layoutIfNeeded()
        return window
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
}
