import AppKit
import SwiftUI

/// The main window's title bar while ``MainScreen`` shows (1.0 D6c2b; board Main2-Home): hidden
/// and transparent over the panels, with an empty unified toolbar. With that toolbar AppKit sets
/// the traffic lights 19 pt in, inside the sidebar panel, and keeps them there on resize, in full
/// screen and on hover; buttons moved by hand go back on the next resize.
private struct MainWindowChrome: ViewModifier {
    @State private var titleBar = MainWindowTitleBar()

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window in
                titleBar.install(in: window)
            })
            .onDisappear {
                titleBar.remove()
            }
    }
}

extension View {
    /// The main window's title bar (``MainWindowTitleBar``) while this view is in the window.
    func mainWindowChrome() -> some View {
        modifier(MainWindowChrome())
    }
}

/// Installs the main window's title bar on one window and puts the previous one back.
final class MainWindowTitleBar {
    /// The empty toolbar's identifier (its only job is the toolbar's height).
    static let toolbarIdentifier = "fxvault.main.titleBar"

    private struct Previous {
        let toolbar: NSToolbar?
        let toolbarStyle: NSWindow.ToolbarStyle
        let titleVisibility: NSWindow.TitleVisibility
        let titlebarAppearsTransparent: Bool
        let titlebarSeparatorStyle: NSTitlebarSeparatorStyle
    }

    private weak var window: NSWindow?
    private var previous: Previous?
    private var toolbarObservation: NSKeyValueObservation?

    func install(in window: NSWindow) {
        remove()
        self.window = window
        previous = Previous(
            toolbar: window.toolbar,
            toolbarStyle: window.toolbarStyle,
            titleVisibility: window.titleVisibility,
            titlebarAppearsTransparent: window.titlebarAppearsTransparent,
            titlebarSeparatorStyle: window.titlebarSeparatorStyle
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.toolbar = Self.makeToolbar()
        // SwiftUI owns the window: if an update clears the toolbar, the lights would drop to the
        // title bar's corner, over the sidebar panel's edge.
        toolbarObservation = window.observe(\.toolbar) { window, _ in
            MainActor.assumeIsolated {
                if window.toolbar == nil {
                    window.toolbar = Self.makeToolbar()
                }
            }
        }
    }

    func remove() {
        toolbarObservation?.invalidate()
        toolbarObservation = nil
        if let window, let previous {
            window.toolbar = previous.toolbar
            window.toolbarStyle = previous.toolbarStyle
            window.titleVisibility = previous.titleVisibility
            window.titlebarAppearsTransparent = previous.titlebarAppearsTransparent
            window.titlebarSeparatorStyle = previous.titlebarSeparatorStyle
        }
        previous = nil
        window = nil
    }

    // A main screen dropped without `onDisappear` must not leave its title bar on the lock screen.
    isolated deinit {
        remove()
    }

    private static func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        return toolbar
    }
}
