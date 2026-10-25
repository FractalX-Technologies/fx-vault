import SwiftUI

/// A keyboard shortcut as a small outlined key (`⌘F` in the sidebar search, `⌘K` in the
/// toolbar; boards Main2-Home, Main2-Expanded). Decorative: the control it sits in says the
/// shortcut to VoiceOver.
///
/// KeyHint("⌘F")
struct KeyHint: View {
    let keys: String

    init(_ keys: String) {
        self.keys = keys
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        Text(verbatim: keys)
            .font(Theme.Typography.monoLabel)
            .foregroundStyle(Theme.Colors.mutedText)
            .padding(.horizontal, Theme.Spacing.xSmall)
            .frame(height: Theme.Layout.keyHintHeight)
            .overlay(shape.strokeBorder(Theme.Colors.hairlineStrong, lineWidth: Theme.Stroke.hairline))
            .accessibilityHidden(true)
    }
}

#Preview {
    HStack {
        KeyHint("⌘F")
        KeyHint("⌘K")
    }
    .padding()
}
