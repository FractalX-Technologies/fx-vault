import SwiftUI

/// Copy All on a place's header (1.0 D6c4; boards Main2-Repository, KV-Place, Org-Visibility):
/// an outline button with the Touch ID glyph. It opens ``CopyAllScreen``, which asks first.
struct CopyAllButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(CopyAllCopy.title, systemImage: "touchid")
        }
        .fxButtonStyle(.outline, size: .compact)
        .disabled(!isEnabled)
        .help(CopyAllCopy.help)
        .accessibilityLabel(CopyAllCopy.accessibilityLabel)
        .accessibilityIdentifier(AccessibilityID.Place.copyAll)
    }
}

/// Copy All in a place's ⋯ More (board Main2-Actions: after Export .env…). A menu item has no
/// trailing lock glyph, so the help says it asks for Touch ID.
struct CopyAllMenuItem: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(CopyAllCopy.title, action: action)
            .disabled(!isEnabled)
            .help(CopyAllCopy.help)
    }
}
