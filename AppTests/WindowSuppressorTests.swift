import AppKit
import Testing
@testable import FXVault

/// FX Vault 1.0.0 and 1.0.1 opened locked with the lock window beside the island: SwiftUI orders
/// the window front after handing it over, and again later in its launch, undoing one close.
@MainActor
@Suite("WindowSuppressor")
struct WindowSuppressorTests {
    @MainActor
    private final class Harness {
        var isSuppressed = true
        var closes = 0
        let window: NSWindow
        lazy var suppressor = WindowSuppressor(isSuppressed: { [unowned self] in isSuppressed }) {
            [unowned self] window in
            closes += 1
            window.close()
        }

        init() {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
        }

        func show() {
            window.orderFront(nil)
            window.update()
        }
    }

    @Test func aSuppressedWindowIsClosedEveryTimeItReachesTheScreen() {
        let harness = Harness()
        harness.suppressor.watch(harness.window)
        #expect(harness.closes == 0, "Before the window is on screen, a close would be undone")
        #expect(harness.window.alphaValue == 0)

        harness.show()
        #expect(harness.closes == 1)
        #expect(!harness.window.isVisible)

        // SwiftUI's second order-front at launch (1.0.1 kept the window from here on).
        harness.show()
        #expect(harness.closes == 2)
        #expect(!harness.window.isVisible, "The lock window stayed beside the island")
        #expect(harness.window.alphaValue == 0, "No frame of it may flash")
    }

    @Test func onceShownOnPurposeTheWindowStaysAndIsOpaque() {
        let harness = Harness()
        harness.suppressor.watch(harness.window)
        harness.show()

        harness.isSuppressed = false
        harness.show()
        #expect(harness.closes == 1)
        #expect(harness.window.isVisible)
        #expect(harness.window.alphaValue == 1)
        harness.window.close()
    }

    @Test func aVisibleWindowIsDecidedAtOnce() {
        let harness = Harness()
        harness.window.orderFront(nil)
        harness.suppressor.watch(harness.window)
        #expect(harness.closes == 1)
        #expect(!harness.window.isVisible)
    }
}
