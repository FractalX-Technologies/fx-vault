import AppKit
import SwiftUI

/// The main window's title bar while ``MainScreen`` shows (1.0 D6c2b; board Main2-Home): hidden
/// and transparent over the panels, with an empty unified toolbar. With that toolbar AppKit sets
/// the traffic lights 19 pt in, inside the sidebar panel, and keeps them there on resize, in full
/// screen and on hover; buttons moved by hand go back on the next resize.
private struct MainWindowChrome: ViewModifier {
    @Binding var isFullScreen: Bool
    @State private var titleBar = MainWindowTitleBar()
    @State private var windowNumber: Int?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window in
                titleBar.install(in: window)
                windowNumber = window.windowNumber
                isFullScreen = window.styleMask.contains(.fullScreen)
            })
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
                if isThisWindow(note) { isFullScreen = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
                if isThisWindow(note) { isFullScreen = false }
            }
            .onDisappear {
                titleBar.remove()
            }
    }

    private func isThisWindow(_ note: Notification) -> Bool {
        windowNumber != nil && (note.object as? NSWindow)?.windowNumber == windowNumber
    }
}

extension View {
    /// The main window's title bar (``MainWindowTitleBar``) while this view is in the window;
    /// `isFullScreen` follows the window (full screen hides the traffic lights).
    func mainWindowChrome(isFullScreen: Binding<Bool>) -> some View {
        modifier(MainWindowChrome(isFullScreen: isFullScreen))
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

    /// One window's title bar before the first main screen, and the main screens holding ours.
    private struct Installation {
        weak var window: NSWindow?
        let previous: Previous
        var owners: Int
        let toolbarObservation: NSKeyValueObservation
    }

    // SwiftUI can show the next main screen before the last one disappears: the last one out
    // restores the title bar, so the overlap neither drops ours nor saves ours as the previous one.
    private static var installations: [ObjectIdentifier: Installation] = [:]

    private var windowID: ObjectIdentifier?

    func install(in window: NSWindow) {
        let id = ObjectIdentifier(window)
        if windowID != id {
            remove()
            windowID = id
            if var installation = Self.installations[id], installation.window === window {
                installation.owners += 1
                Self.installations[id] = installation
            } else {
                Self.installations[id] = Installation(
                    window: window,
                    previous: Previous(
                        toolbar: window.toolbar,
                        toolbarStyle: window.toolbarStyle,
                        titleVisibility: window.titleVisibility,
                        titlebarAppearsTransparent: window.titlebarAppearsTransparent,
                        titlebarSeparatorStyle: window.titlebarSeparatorStyle
                    ),
                    owners: 1,
                    // SwiftUI owns the window: if an update clears the toolbar, the lights would
                    // drop to the title bar's corner, over the sidebar panel's edge.
                    toolbarObservation: window.observe(\.toolbar) { window, _ in
                        MainActor.assumeIsolated {
                            if window.toolbar == nil {
                                window.toolbar = Self.makeToolbar()
                            }
                        }
                    }
                )
            }
        }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        if window.toolbar?.identifier != Self.toolbarIdentifier {
            window.toolbar = Self.makeToolbar()
        }
    }

    func remove() {
        guard let id = windowID else { return }
        windowID = nil
        guard var installation = Self.installations[id] else { return }
        installation.owners -= 1
        guard installation.owners == 0 else {
            Self.installations[id] = installation
            return
        }
        Self.installations[id] = nil
        installation.toolbarObservation.invalidate()
        guard let window = installation.window else { return }
        let previous = installation.previous
        window.toolbar = previous.toolbar
        window.toolbarStyle = previous.toolbarStyle
        window.titleVisibility = previous.titleVisibility
        window.titlebarAppearsTransparent = previous.titlebarAppearsTransparent
        window.titlebarSeparatorStyle = previous.titlebarSeparatorStyle
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
