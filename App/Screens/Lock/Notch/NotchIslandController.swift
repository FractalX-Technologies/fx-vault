import AppKit
import SwiftUI

/// Shows the island while the vault is locked and FX Vault is active; the main window stays
/// closed meanwhile (1.0 brief, "Unlock from the notch").
@MainActor
final class NotchIslandController {
    let model: NotchIslandModel
    /// The vault is locked and the island is the unlock UI; it appears whenever FX Vault is active.
    private(set) var isPresented = false
    private let presenter: NotchPanelPresenter
    private var hideTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    /// The quick vault's request ended with the island out of sight (1.0 Q1).
    var onQuickVaultRequestEnded: (() -> Void)?

    init(lock: LockViewModel) {
        let model = NotchIslandModel(lock: lock)
        self.model = model
        presenter = NotchPanelPresenter(notchHeight: { model.notchHeight }) {
            NotchIslandView(model: model)
        }
        model.onSizeChange = { [weak self] size in
            self?.presenter.place(size: size)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showIfPresented()
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endQuickVaultRequest()
            }
        }
    }

    /// Starts a lock's island: on screen now when FX Vault is active, else at its next activation
    /// (a screen lock or sleep must not bring FX Vault forward). `opensQuickVault`: the quick
    /// vault's shortcut asked, and it opens after the unlock (board QuickVault-Locked).
    func present(opensQuickVault: Bool = false) {
        hideTask?.cancel()
        model.reset()
        model.opensQuickVault = opensQuickVault
        isPresented = true
        showIfPresented()
    }

    /// Another app came forward: the shortcut's request was for then, so a later unlock opens the
    /// window. Not during an unlock (a Touch ID prompt may take the focus).
    private func endQuickVaultRequest() {
        guard model.opensQuickVault, !model.lock.isUnlocking else { return }
        model.opensQuickVault = false
        onQuickVaultRequestEnded?()
    }

    /// Shows "Unlocked" for a moment, then goes away.
    func dismissUnlocked() {
        isPresented = false
        model.lock.dropIslandTouchID()
        guard presenter.isVisible else { return }
        model.isUnlocked = true
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Theme.Durations.islandUnlocked)
            guard !Task.isCancelled else { return }
            self?.presenter.hide()
        }
    }

    /// Recovery and the Touch ID offer need the window; the island steps aside.
    func dismiss() {
        hideTask?.cancel()
        isPresented = false
        model.lock.dropIslandTouchID()
        presenter.hide()
    }

    private func showIfPresented() {
        guard isPresented, NSApp.isActive else { return }
        model.notchHeight = NotchPanelPresenter.screenNotchHeight
        // Before the view shows and before the auto-prompt evaluates it.
        if model.lock.islandTouchID == nil { model.lock.prepareIslandTouchID() }
        presenter.show()
        Task {
            await model.lock.autoPromptIfAllowed(isAppActive: NSApp.isActive, isSceneActive: true)
        }
    }
}

/// A borderless panel above the menu bar, so the island merges with the notch. Flat (no
/// shadow), kept out of screen recordings, and hidden while another app is active.
final class NotchIslandPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = true
        isMovable = false
        isReleasedWhenClosed = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    // A borderless panel cannot become key by default, and the password field needs the keyboard.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
