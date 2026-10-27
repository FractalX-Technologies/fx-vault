import SwiftUI

extension View {
    /// The main window's opening (1.0.2, after Cursor): FX Vault's mark, small and grey, on the
    /// main window's soft ground, then the content fades in under it.
    func fxLaunchSplash() -> some View {
        modifier(LaunchSplash())
    }
}

/// Shown each time the window's content appears (launch, and the window again after an unlock).
/// Decorative: hidden from VoiceOver and never takes a click.
private struct LaunchSplash: ViewModifier {
    @State private var isShowing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isShowing ? 0 : 1)
            .scaleEffect(isShowing && !reduceMotion ? Theme.Layout.splashContentScale : 1)
            .overlay {
                if isShowing {
                    splash
                        .transition(.opacity)
                }
            }
            .task {
                try? await Task.sleep(for: Theme.Durations.splashHold)
                withAnimation(Theme.Durations.splashFade) {
                    isShowing = false
                }
            }
    }

    private var splash: some View {
        ZStack {
            MainWindowGround()
            BrandMark(size: Theme.Layout.splashMark, color: Theme.Colors.subtleText, center: .outlined)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
