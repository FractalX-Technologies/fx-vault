import AppKit
import SwiftUI

/// Shows the quick vault (``QuickVaultViewModel``) in the island's panel, placed as the island is
/// (``NotchGeometry``) and kept out of screen capture. Losing the focus closes it, except while
/// Touch ID or the password check runs; closing gives the focus back to the app it opened over.
@MainActor
final class QuickVaultController {
    private let model: QuickVaultViewModel
    private var panel: NotchIslandPanel?
    private var observers: [NSObjectProtocol] = []
    /// Opened from another app: the panel waits for FX Vault's activation, which would give the
    /// key back to an older window of FX Vault and close the quick vault at once.
    private var showsAfterActivation = false

    init(model: QuickVaultViewModel) {
        self.model = model
        model.onOpenChange = { [weak self] isOpen, returnsFocus in
            if isOpen {
                self?.show()
            } else {
                self?.hide(returningFocus: returnsFocus)
            }
        }
        model.onSizeChange = { [weak self] size in
            self?.place(size: size)
        }
        let center = NotificationCenter.default
        let names = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didResignKeyNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let sender = (notification.object as AnyObject?).map(ObjectIdentifier.init)
                let name = notification.name
                MainActor.assumeIsolated {
                    self?.handle(name, from: sender)
                }
            })
        }
    }

    private func handle(_ name: Notification.Name, from sender: ObjectIdentifier?) {
        switch name {
        case NSApplication.didBecomeActiveNotification:
            guard showsAfterActivation else { return }
            showsAfterActivation = false
            present()
        case NSWindow.didResignKeyNotification:
            guard let panel, sender == ObjectIdentifier(panel) else { return }
            model.didLoseFocus()
        default:
            model.didLoseFocus()
        }
    }

    private func show() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        model.notchHeight = screen?.safeAreaInsets.top ?? 0
        // The shortcut works from any app: FX Vault comes forward so the field gets the keys.
        guard NSApp.isActive else {
            showsAfterActivation = true
            NSApp.activate()
            return
        }
        present()
    }

    private func present() {
        guard model.isOpen else { return }
        let panel = panel ?? makePanel()
        place(size: panel.contentView?.fittingSize ?? .zero)
        panel.makeKeyAndOrderFront(nil)
    }

    private func hide(returningFocus: Bool) {
        showsAfterActivation = false
        panel?.orderOut(nil)
        // Opened over another app with no FX Vault window: that app gets the keys back.
        guard returningFocus, NSApp.isActive else { return }
        let showsWindow = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeMain }
        if !showsWindow {
            NSApp.hide(nil)
        }
    }

    private func makePanel() -> NotchIslandPanel {
        let panel = NotchIslandPanel()
        // Over other apps' windows, the panel needs its edge (board QuickVault-Search).
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: QuickVaultView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func place(size: CGSize) {
        guard let panel, size.width > 0, size.height > 0,
              let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = NotchGeometry.islandFrame(
            size: size,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            notchHeight: model.notchHeight
        )
        panel.setFrame(frame, display: true)
    }
}
