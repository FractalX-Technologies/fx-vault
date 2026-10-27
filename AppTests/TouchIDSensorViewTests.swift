import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI
import Testing
import VaultData
@testable import FXVault

/// The island's Touch ID glyph (1.0 B11e2). `LAAuthenticationView` takes its control size's side
/// whatever frame it gets, so `.large` drew a 128 pt fingerprint in the island (1.0.0).
@MainActor
@Suite("Touch ID sensor size")
struct TouchIDSensorViewTests {
    // Theme.Layout.touchIDGlyph and touchIDGlyphSmall (checked below), plus a side between sizes.
    @Test(arguments: [24.0, 14.0, 40.0] as [CGFloat])
    func theSensorIsDrawnAtTheGlyphsSide(_ side: CGFloat) {
        let sensor = TouchIDSensorView.Sensor(side: side)
        let view = LAAuthenticationView(context: LAContext(), controlSize: sensor.controlSize)

        #expect(view.fittingSize.width == sensor.nativeSide, "The table of native sides is wrong")
        #expect(sensor.nativeSide >= side, "Scaled up, the glyph would blur")
        #expect(sensor.nativeSide * sensor.scale == side)
    }

    @Test func theSmallestSizeThatCoversTheSideIsChosen() {
        #expect(TouchIDSensorView.Sensor(side: 14).controlSize == .mini)
        #expect(TouchIDSensorView.Sensor(side: 24).controlSize == .small)
        #expect(TouchIDSensorView.Sensor(side: 40).controlSize == .regular)
        #expect(TouchIDSensorView.Sensor(side: 200).controlSize == .large)
    }

    @Test func theIslandsGlyphsMatchTheirText() {
        // The title (22 pt) and caption (12 pt) symbols they stand beside.
        #expect(Theme.Layout.touchIDGlyph == 24)
        #expect(Theme.Layout.touchIDGlyphSmall == 14)
    }

    // MARK: - One sensor per window

    @Observable
    final class Check {
        var session: BiometricSession?
        init(_ session: BiometricSession) { self.session = session }
    }

    private struct Host: View {
        let check: Check
        var body: some View {
            TouchIDSensorView(session: check.session, side: Theme.Layout.touchIDGlyph, font: Theme.Typography.title)
        }
    }

    private static func sensors(in view: NSView) -> Int {
        (view is LAAuthenticationView ? 1 : 0) + view.subviews.reduce(0) { $0 + sensors(in: $1) }
    }

    /// 1.0.1 crashed after a few touches ("There may only be 1 NSOcclusionDetectionView per
    /// window"): a renewed check arrived in an animated update, so the old sensor stayed for its
    /// removal transition beside the new one, and the next Touch ID event added a second one.
    @Test func aRenewedCheckReplacesTheSensorWithoutAnOverlap() {
        let biometrics = FakeBiometricKeyStore()
        let prompt = BiometricPrompt(reason: "unlock", fallbackTitle: "Password")
        let check = Check(biometrics.makeSession(prompt: prompt))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Host(check: check))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(Self.sensors(in: host) == 1)

        withAnimation(Theme.Durations.spring) {
            check.session = biometrics.makeSession(prompt: prompt)
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        #expect(Self.sensors(in: host) == 1, "Two sensors in one window crash on the next touch")
        window.close()
    }
}
