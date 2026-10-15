import AppKit
import Testing
@testable import FXVault

/// Smoke tests for the app shell. The host app runs in test mode (`AppContainer.preview`),
/// so these tests never touch the real vault, keychain or gh.
@MainActor
@Suite("App shell")
struct AppSmokeTests {
    @Test func hostedTestsRunSideEffectFree() throws {
        #expect(AppContainer.Mode.forCurrentProcess() == .preview)
        let viewModel = try #require(AppBootstrap.forCurrentProcess().viewModel)
        #expect(viewModel.container.mode == .preview)
        #expect(!viewModel.container.hasSideEffects)
        #expect(viewModel.container.vaultDirectory == nil)
        #expect(viewModel.container.vaultManager.state == .noVault)
    }

    @Test func liveContainerOutsideTests() {
        #expect(AppContainer.Mode.forCurrentProcess(environment: [:]) == .live)
    }

    @Test func previewContainerStartsInOnboarding() throws {
        let viewModel = AppViewModel(container: try AppContainer.preview())
        #expect(viewModel.phase == .onboarding)
    }

    /// PKG-6: the standard About panel shows `Credits.rtf`, which carries the MIT, ISC and
    /// CC BY notices the app and DMG must ship with.
    @Test func creditsShipTheThirdPartyNotices() throws {
        let url = try #require(Bundle.main.url(forResource: "Credits", withExtension: "rtf"))
        let credits = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        for notice in ["MIT License", "GRDB.swift", "libsodium", "ISC License", "EFF Large Wordlist", "creativecommons.org/licenses/by/3.0"] {
            #expect(credits.contains(notice), "missing \(notice)")
        }
    }

    /// Asset catalog color set names behind `Theme.Colors`.
    /// (v0.3.0 renamed them; `DesignTokenTests` checks the exact values.)
    @Test(arguments: [
        "Brand", "Ground", "Surface", "Surface2", "Card", "Ink", "MutedText", "SubtleText",
        "Hairline", "HairlineStrong", "Success", "Warning", "Danger",
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
