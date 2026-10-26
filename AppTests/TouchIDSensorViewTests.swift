import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import Testing
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
}
