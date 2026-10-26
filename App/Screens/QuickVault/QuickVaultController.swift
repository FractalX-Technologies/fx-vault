import AppKit
import SwiftUI

/// Shows the quick vault (``QuickVaultViewModel``) in the island's panel, placed as the island is
/// (``NotchPanelPresenter``) and kept out of screen capture. Losing the focus closes it, except while
/// Touch ID or the password check runs; closing gives the focus back to the app it opened over.
@MainActor
final class QuickVaultController {
    private let model: QuickVaultViewModel
    private let presenter: NotchPanelPresenter
    private var observers: [NSObjectProtocol] = []
    /// Opened from another app: the panel waits for FX Vault's activation, which would give the
    /// key back to an older window of FX Vault and close the quick vault at once.
    private var showsAfterActivation = false

    init(model: QuickVaultViewModel) {
        self.model = model
        presenter = NotchPanelPresenter(hasShadow: true, notchHeight: { model.notchHeight }) {
            QuickVaultView(model: model)
        }
        model.onShow = { [weak self] in
            self?.show()
        }
        model.onHide = { [weak self] returnFocusTo in
            self?.hide(returningFocusTo: returnFocusTo)
        }
        model.onSizeChange = { [weak self] size in
            self?.presenter.place(size: size)
        }
        model.hasFocus = { [weak self] in
            self?.hasFocus ?? false
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

    /// After a Touch ID prompt the key window may be none for a moment: only another FX Vault
    /// window with the keys, or another app in front, counts as a lost focus.
    private var hasFocus: Bool {
        guard NSApp.isActive else { return false }
        guard let key = NSApp.keyWindow else { return true }
        return key === presenter.panel
    }

    private func handle(_ name: Notification.Name, from sender: ObjectIdentifier?) {
        switch name {
        case NSApplication.didBecomeActiveNotification:
            guard showsAfterActivation else { return }
            showsAfterActivation = false
            present()
        case NSWindow.didResignKeyNotification:
            guard let panel = presenter.panel, sender == ObjectIdentifier(panel) else { return }
            model.didLoseFocus()
        default:
            model.didLoseFocus()
        }
    }

    private func show() {
        model.notchHeight = NotchPanelPresenter.screenNotchHeight
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
        presenter.show()
    }

    /// Each open draws a new panel, so a value revealed last time never flashes in the old frame.
    private func hide(returningFocusTo processID: pid_t?) {
        showsAfterActivation = false
        presenter.hide(dropping: true)
        // That app comes forward even with FX Vault's main window open, which stays behind it.
        guard let processID, let app = NSRunningApplication(processIdentifier: processID) else { return }
        NSApp.yieldActivation(to: app)
        _ = app.activate(from: .current, options: [])
    }
}
