import SwiftUI

/// Chooses the screen for the current vault phase.
///
/// Placeholder: Onboarding, Lock and Main screens replace the phase cards in M1.
struct RootScreen: View {
    let viewModel: AppViewModel

    var body: some View {
        content
            .frame(
                minWidth: Theme.Layout.windowMinWidth,
                maxWidth: .infinity,
                minHeight: Theme.Layout.windowMinHeight,
                maxHeight: .infinity
            )
            .background(Theme.Colors.background)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .onboarding:
            PhasePlaceholderView(
                systemImage: "sparkles",
                title: String(localized: "root.onboarding.title", defaultValue: "Welcome to FX Vault"),
                message: String(
                    localized: "root.onboarding.message",
                    defaultValue: "Create a vault to manage your GitHub secrets and variables."
                )
            )
        case .locked:
            PhasePlaceholderView(
                systemImage: "lock.fill",
                title: String(localized: "root.locked.title", defaultValue: "FX Vault is locked"),
                message: String(localized: "root.locked.message", defaultValue: "Unlock it with your master password.")
            )
        case .unlocked:
            PhasePlaceholderView(
                systemImage: "lock.open.fill",
                title: String(localized: "root.unlocked.title", defaultValue: "Vault unlocked"),
                message: String(localized: "root.unlocked.message", defaultValue: "Your repositories will appear here.")
            )
        }
    }
}

/// A centered icon, title and message for a phase that has no screen yet.
private struct PhasePlaceholderView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.system(size: Theme.Layout.placeholderIconSize))
                .foregroundStyle(Theme.Colors.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xxLarge)
    }
}

#Preview {
    RootScreen(viewModel: AppViewModel(container: .preview))
}
