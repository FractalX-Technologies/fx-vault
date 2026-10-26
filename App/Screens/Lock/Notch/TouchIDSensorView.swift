import LocalAuthenticationEmbeddedUI
import SwiftUI
import VaultData

/// The island's Touch ID glyph. With a check (1.0 B11e2) it is the system's
/// `LAAuthenticationView` bound to that check's context, so the evaluation shows here instead of
/// in a system alert; without one it is the plain symbol, as before.
struct TouchIDSensorView: View {
    let session: BiometricSession?
    /// The glyph's side in points, matching the plain symbol in `font`.
    let side: CGFloat
    let font: Font

    var body: some View {
        if let session {
            let sensor = Sensor(side: side)
            SensorRepresentable(context: session.context, controlSize: sensor.controlSize)
                // A new check needs a new view: the pairing is made once, at creation.
                .id(session.id)
                .frame(width: sensor.nativeSide, height: sensor.nativeSide)
                .scaleEffect(sensor.scale)
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "touchid")
                .font(font)
        }
    }

    /// `LAAuthenticationView` keeps its control size's side whatever its frame (16, 32, 64 or
    /// 128 pt; `.large` drew a 128 pt fingerprint in 1.0.0): the smallest one that covers `side`,
    /// scaled down to it.
    struct Sensor {
        let controlSize: NSControl.ControlSize
        let nativeSide: CGFloat
        let scale: CGFloat

        private static let sizes: [(NSControl.ControlSize, CGFloat)] = [
            (.mini, 16), (.small, 32), (.regular, 64), (.large, 128),
        ]

        init(side: CGFloat) {
            let size = Self.sizes.first { $0.1 >= side } ?? Self.sizes[Self.sizes.count - 1]
            controlSize = size.0
            nativeSide = size.1
            scale = min(1, side / size.1)
        }
    }
}

private struct SensorRepresentable: NSViewRepresentable {
    let context: LAContext
    let controlSize: NSControl.ControlSize

    func makeNSView(context _: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: context, controlSize: controlSize)
    }

    func updateNSView(_: LAAuthenticationView, context _: Context) {}
}
