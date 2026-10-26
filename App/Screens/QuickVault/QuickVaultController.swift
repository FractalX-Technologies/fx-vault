import AppKit
import SwiftUI

/// Shows the quick vault (``QuickVaultViewModel``) in the island's panel (``NotchPanelPresenter``),
/// out of screen capture. Opening activates FX Vault, so an open main window comes forward behind
/// it until it closes. Losing the focus closes it, except while Touch ID or the password check
/// runs; esc and the shortcut give the focus back to the app it opened over.
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
        model.onHide = { [weak self] returnsFocus, app in
            self?.hide(returningFocus: returnsFocus, to: app)
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
            NSWindow.didBecomeKeyNotification,
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
        case NSWindow.didBecomeKeyNotification:
            // Another FX Vault window took the keys, also when the panel had none (after a check).
            guard !showsAfterActivation, let panel = presenter.panel, panel.isVisible,
                  sender != ObjectIdentifier(panel) else { return }
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
    private func hide(returningFocus: Bool, to app: (any QuickVaultReturnApp)?) {
        showsAfterActivation = false
        presenter.hide(dropping: true)
        guard returningFocus, NSApp.isActive else { return }
        // That app comes forward even with FX Vault's main window open, which stays behind it.
        if let app, app.takeKeysFromFXVault() {
            return
        }
        // No app to go back to (opened from FX Vault, or it quit): without a window, step back.
        let showsWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if !showsWindow {
            NSApp.hide(nil)
        }
    }
}

extension NSRunningApplication: QuickVaultReturnApp {
    func takeKeysFromFXVault() -> Bool {
        NSApp.yieldActivation(to: self)
        return activate(from: .current, options: [])
    }
}
