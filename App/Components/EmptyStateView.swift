import SwiftUI

/// A centered icon, title, message and optional action for an empty column or list.
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
                .font(.system(size: Theme.Layout.emptyStateIconSize, weight: .light))
                .foregroundStyle(Theme.Colors.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(message)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
            actions()
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
