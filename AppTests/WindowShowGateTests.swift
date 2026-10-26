import AppKit
import Testing
@testable import FXVault

/// FX Vault 1.0.0 opened locked with the lock window beside the island: the window was closed
/// before SwiftUI ordered it front, which undid the close.
@MainActor
@Suite("WindowShowGate")
struct WindowShowGateTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aWindowNotYetOnScreenWaitsTransparentAndClosesOnceShown() {
        let window = makeWindow()
        let gate = WindowShowGate()
        var runs = 0
        gate.onScreen(window) {
            runs += 1
            window.close()
        }
        #expect(runs == 0, "Before the window is on screen, a close would be undone")
        #expect(window.alphaValue == 0)

        window.orderFront(nil)
        window.update()

        #expect(runs == 1)
        #expect(!window.isVisible, "The lock window stayed beside the island")
        #expect(window.alphaValue == 1, "It must come back opaque when it reopens")

        window.orderFront(nil)
        window.update()
        #expect(runs == 1, "The action runs once")
        window.close()
    }

    @Test func aVisibleWindowRunsAtOnce() {
        let window = makeWindow()
        window.orderFront(nil)
        let gate = WindowShowGate()
        var runs = 0
        gate.onScreen(window) { runs += 1 }
        #expect(runs == 1)
        #expect(window.alphaValue == 1)
        window.close()
    }

    @Test func cancelDropsTheActionAndRestoresTheWindow() {
        let window = makeWindow()
        let gate = WindowShowGate()
        var runs = 0
        gate.onScreen(window) { runs += 1 }
        gate.cancel()
        window.orderFront(nil)
        window.update()
        #expect(runs == 0)
        #expect(window.alphaValue == 1)
        window.close()
    }
}
