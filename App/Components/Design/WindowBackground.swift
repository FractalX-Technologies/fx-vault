import AppKit
import SwiftUI

/// The global chrome of every FX Vault window (docs/DESIGN.md, "Windows"): the `ground`
/// background behind SwiftUI content and in the `NSWindow` itself (title bar, resize edges,
/// sheet backdrops), SF Pro 13 as the default font and the brand tint. It does not set a
/// foreground color: `.primary` must keep flipping to white on selected rows.
private struct FXWindowBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Typography.body)
            .tint(Theme.Colors.brand)
            .background(Theme.Colors.ground.ignoresSafeArea())
            .background(WindowAccessor { window in
                window.backgroundColor = Theme.Colors.windowBackground
            })
    }
}

extension View {
    /// Applies the FractalX window chrome. Use once per scene, on the scene's root view.
    ///
    /// ```swift
    /// Window(…) { RootScreen(viewModel: viewModel).fxWindowBackground() }
    /// ```
    func fxWindowBackground() -> some View {
        modifier(FXWindowBackground())
    }
}
