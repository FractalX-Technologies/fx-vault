import Testing
@testable import FXVault

/// The main window's glass (1.0.2, Cursor-like): the tints let the blurred desktop through,
/// except with Reduce Transparency, which asks for solid colors.
@MainActor
@Suite("WindowGlass")
struct WindowGlassTests {
    @Test func theTintsAreTranslucent() {
        #expect(WindowGlass.opacity(WindowGlass.ground, reduceTransparency: false) < 1)
        #expect(WindowGlass.opacity(WindowGlass.sidebar, reduceTransparency: false) < 1)
    }

    @Test func reduceTransparencyMakesThemOpaque() {
        #expect(WindowGlass.opacity(WindowGlass.ground, reduceTransparency: true) == 1)
        #expect(WindowGlass.opacity(WindowGlass.sidebar, reduceTransparency: true) == 1)
    }
}
