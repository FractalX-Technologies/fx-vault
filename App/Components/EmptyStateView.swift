import SwiftUI

/// A centered icon, title, message and optional action for an empty column or list (FractalX:
/// light subtle symbol, 15 pt 500 ink title, muted callout message, pill actions below).
struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    init(
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: systemImage)
                .font(Theme.Typography.emptyStateIcon)
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityHidden(true)
            Text(title)
                .fxTextStyle(.headline)
                .foregroundStyle(Theme.Colors.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .fxTextStyle(.callout)
                .foregroundStyle(Theme.Colors.mutedText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
                .padding(.top, Theme.Spacing.xSmall)
        }
        .frame(maxWidth: Theme.Layout.emptyStateMaxWidth)
        .padding(Theme.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

#Preview {
    EmptyStateView(
        systemImage: "tray",
        title: String(localized: "main.sidebar.empty.title", defaultValue: "No repositories yet"),
        message: String(
            localized: "main.sidebar.empty.message",
            defaultValue: "Repositories of your GitHub CLI accounts appear here."
        )
    )
}
