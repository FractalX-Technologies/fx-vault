import LocalAuthenticationEmbeddedUI
import SwiftUI
import VaultData

/// The island's Touch ID glyph. With a check (1.0 B11e2) it is the system's
/// `LAAuthenticationView` bound to that check's context, so the evaluation shows here instead of
/// in a system alert; without one it is the plain symbol, as before.
struct TouchIDSensorView: View {
    let session: BiometricSession?
    let controlSize: NSControl.ControlSize
    let font: Font

    var body: some View {
        if let session {
            SensorRepresentable(context: session.context, controlSize: controlSize)
                // A new check needs a new view: the pairing is made once, at creation.
                .id(session.id)
                .fixedSize()
                .accessibilityHidden(true)
        } else {
            Image(systemName: "touchid")
                .font(font)
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
