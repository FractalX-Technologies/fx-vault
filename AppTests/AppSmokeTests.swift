import AppKit
import Testing
@testable import FXVault

/// Smoke tests for the app shell. The host app runs in test mode (`AppContainer.preview`),
/// so these tests never touch the real vault, keychain or gh.
@MainActor
@Suite("App shell")
struct AppSmokeTests {
    @Test func hostedTestsRunSideEffectFree() {
        let container = AppContainer.forCurrentProcess()
        #expect(container == .preview)
        #expect(!container.hasSideEffects)
    }

    @Test func liveContainerOutsideTests() {
        #expect(AppContainer.forCurrentProcess(environment: [:]) == .live)
    }

    @Test func newViewModelStartsInOnboarding() {
        let viewModel = AppViewModel(container: .test)
        #expect(viewModel.phase == .onboarding)
    }

    /// Asset catalog color set names behind `Theme.Colors`.
    @Test(arguments: [
        "Accent", "Background", "Surface", "TextPrimary", "TextSecondary",
        "Success", "Warning", "Danger", "Pending",
    ])
    func semanticColorHasLightAndDarkVariants(_ name: String) throws {
        let color = try #require(NSColor(named: name))
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        var lightValue: NSColor?
        var darkValue: NSColor?
        light.performAsCurrentDrawingAppearance { lightValue = color.usingColorSpace(.sRGB) }
        dark.performAsCurrentDrawingAppearance { darkValue = color.usingColorSpace(.sRGB) }
        let resolvedLight = try #require(lightValue)
        let resolvedDark = try #require(darkValue)
        #expect(resolvedLight != resolvedDark)
    }
}
