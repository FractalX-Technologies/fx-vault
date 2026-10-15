import SwiftUI

// Layout shared by the full-window screens outside the main window (lock, recovery reset,
// onboarding, GitHub CLI setup) and their sheets (Touch ID offer, Settings sheets), in the
// FractalX language (docs/DESIGN.md, boards Lock, Onboarding and SyncReview). The header, error,
// checkbox, link and sheet chrome are design components (App/Components/Design/SheetChrome.swift);
// this file only lays them out.

/// A full-window screen with one centered card on the dotted ground (recovery reset, GitHub CLI
/// setup). Scrolls when the window is shorter than the card.
struct ShellCardLayout<Content: View>: View {
    var width: CGFloat = Theme.Layout.cardWidth
    @ViewBuilder let content: () -> Content

    var body: some View {
        ShellCenteredScroll {
            Card(spacing: Theme.Spacing.xLarge) {
                content()
            }
            .frame(width: width)
        }
    }
}

/// Centers its content in the window on the dotted ground and scrolls it when the window is
/// too short (lock screen, ``ShellCardLayout``).
struct ShellCenteredScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content()
                    .padding(.vertical, Theme.Spacing.xxxLarge)
                    .padding(.horizontal, Theme.Spacing.xHuge)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(DotGridBackground())
    }
}

/// The label of a forward primary pill: the title and a trailing arrow (Unlock, Continue).
struct ShellForwardLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(title)
            Image(systemName: "arrow.right")
                .accessibilityHidden(true)
        }
    }
}

/// The footer of a shell screen or sheet: an optional leading view, then the buttons on the
/// trailing side with a spinner while `isWorking` (Cancel left of the primary).
struct ShellFooter<Leading: View, Buttons: View>: View {
    var isWorking = false
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        HStack(spacing: Theme.Spacing.mediumMinus) {
            leading()
            Spacer(minLength: Theme.Spacing.small)
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            buttons()
        }
    }
}

extension ShellFooter where Leading == EmptyView {
    init(isWorking: Bool = false, @ViewBuilder buttons: @escaping () -> Buttons) {
        self.isWorking = isWorking
        self.leading = { EmptyView() }
        self.buttons = buttons
    }
}

#Preview("Shell") {
    ShellCardLayout {
        SheetHeader(
            label: "GitHub CLI",
            title: "Install the GitHub CLI",
            subtitle: "FX Vault talks to GitHub only through the GitHub CLI (gh)."
        )
        InlineErrorView(error: ErrorPresentationModel(title: "Could not unlock", message: "The password is wrong."))
        FXCheckboxRow(title: "I saved the new recovery key", isOn: .constant(true))
        ShellFooter(isWorking: true) {
            Button {} label: { Text(verbatim: "Use recovery key") }.fxLinkButtonStyle()
        } buttons: {
            Button {} label: { Text(verbatim: "Cancel") }.fxButtonStyle(.secondary, size: .large)
            Button {} label: { ShellForwardLabel(title: "Continue") }.fxButtonStyle(.primary, size: .large)
        }
    }
    .frame(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
}
