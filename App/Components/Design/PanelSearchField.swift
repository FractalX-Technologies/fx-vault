import SwiftUI

/// The search field at the top of a main-window panel (board Main2-Home): a magnifying glass,
/// a plain 12 pt field and an optional trailing hint on `surface2`. Esc clears it. The sidebar
/// adds its ⌘F hint; Settings use it for Search Settings.
struct PanelSearchField<Trailing: View>: View {
    let prompt: String
    let label: String
    let accessibilityID: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.compactRow, style: .continuous)
        HStack(spacing: Theme.Spacing.smallMinus) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Typography.caption)
                .focused(isFocused)
                .accessibilityLabel(label)
                .accessibilityIdentifier(accessibilityID)
                .onExitCommand {
                    text = ""
                }
            trailing()
        }
        .padding(.horizontal, Theme.Spacing.small)
        .frame(height: Theme.Layout.sidebarControlHeight)
        .background(Theme.Colors.surface2, in: shape)
    }
}

extension PanelSearchField where Trailing == EmptyView {
    init(
        prompt: String,
        label: String,
        accessibilityID: String,
        text: Binding<String>,
        isFocused: FocusState<Bool>.Binding
    ) {
        self.init(prompt: prompt, label: label, accessibilityID: accessibilityID, text: text, isFocused: isFocused) {
            EmptyView()
        }
    }
}
