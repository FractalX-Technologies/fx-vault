import AppKit
import SwiftUI

/// Shows the island while the vault is locked and FX Vault is active; the main window stays
/// closed meanwhile (1.0 brief, "Unlock from the notch").
@MainActor
final class NotchIslandController {
    let model: NotchIslandModel
    /// The vault is locked and the island is the unlock UI; it appears whenever FX Vault is active.
    private(set) var isPresented = false
    private var panel: NotchIslandPanel?
    private var hideTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    /// The quick vault's request ended with the island out of sight (1.0 Q1).
    var onQuickVaultRequestEnded: (() -> Void)?

    init(lock: LockViewModel) {
        model = NotchIslandModel(lock: lock)
        model.onSizeChange = { [weak self] size in
            self?.place(size: size)
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
        guard let panel, panel.isVisible else { return }
        model.isUnlocked = true
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Theme.Durations.islandUnlocked)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    /// Recovery and the Touch ID offer need the window; the island steps aside.
    func dismiss() {
        hideTask?.cancel()
        isPresented = false
        panel?.orderOut(nil)
    }

    private func showIfPresented() {
        guard isPresented, NSApp.isActive else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        model.notchHeight = screen?.safeAreaInsets.top ?? 0
        let panel = panel ?? makePanel()
        place(size: panel.contentView?.fittingSize ?? .zero)
        panel.makeKeyAndOrderFront(nil)
        Task {
            await model.lock.autoPromptIfAllowed(isAppActive: NSApp.isActive, isSceneActive: true)
        }
    }

    private func makePanel() -> NotchIslandPanel {
        let panel = NotchIslandPanel()
        let hosting = NSHostingView(rootView: NotchIslandView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func place(size: CGSize) {
        guard let panel, size.width > 0, size.height > 0, let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = NotchGeometry.islandFrame(
            size: size,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            notchHeight: model.notchHeight
        )
        panel.setFrame(frame, display: true)
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
