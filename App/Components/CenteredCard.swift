import SwiftUI

/// The centered, fixed-width card used by onboarding, the lock screen and the recovery reset.
struct CenteredCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                content()
            }
            .padding(Theme.Spacing.xxLarge)
            .frame(width: Theme.Layout.cardWidth)
            .background(Theme.Colors.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large)
                    .strokeBorder(Theme.Colors.textPrimary.opacity(Theme.Opacity.cardBorder))
            )
            .padding(Theme.Spacing.xxLarge)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
    }
}

/// An icon, title and subtitle at the top of a ``CenteredCard``.
struct CardHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String?

    init(systemImage: String, title: String, subtitle: String? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: Theme.Layout.heroIconSize, weight: .light))
                .foregroundStyle(Theme.Colors.accent)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// An inline error under a form.
struct InlineErrorView: View {
    let error: ErrorPresentationModel

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                Text(error.title)
                    .font(Theme.Typography.callout.weight(.semibold))
                Text(error.message)
                    .font(Theme.Typography.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "exclamationmark.circle.fill")
        }
        .foregroundStyle(Theme.Colors.danger)
        .accessibilityElement(children: .combine)
    }
}
