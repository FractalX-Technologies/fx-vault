import AppKit
import SwiftUI

/// Hands the hosting `NSWindow` to `onWindow` once the view is in a window.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowReportingView, context: Context) {
        view.onWindow = onWindow
    }

    final class WindowReportingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindow?(window)
            }
        }
    }
}

/// Excludes the window from screen capture and screen sharing while the modified view is on
/// screen (best effort, §5.11: recovery keys, passphrases and revealed values).
private struct ScreenCaptureProtection: ViewModifier {
    @State private var window: NSWindow?
    @State private var previousSharingType: NSWindow.SharingType?

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window in
                guard self.window !== window else { return }
                self.window = window
                previousSharingType = window.sharingType
                window.sharingType = .none
            })
            .onDisappear {
                if let window, let previousSharingType {
                    window.sharingType = previousSharingType
                }
                window = nil
                previousSharingType = nil
            }
    }
}

extension View {
    /// Sets `NSWindow.sharingType = .none` on the hosting window while this view is visible.
    func screenCaptureProtected() -> some View {
        modifier(ScreenCaptureProtection())
    }
}
