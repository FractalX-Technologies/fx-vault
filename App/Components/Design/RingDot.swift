import SwiftUI

/// A hollow ring (`Theme.Stroke.changedDot` wide): a place changed on GitHub and a change that
/// stays pending (ink, boards Main2-Repository and Sync-Done), a Sync line still waiting
/// (`hairlineStrong`, board Sync-Progress), the finish's 44 pt mark (`success`).
struct RingDot: View {
    var color: Color = Theme.Colors.ink
    var size: CGFloat = Theme.Layout.changedDotSize

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: Theme.Stroke.changedDot)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A filled 6 pt dot beside a state: one that is fine (`success`) or over (`hairlineStrong`)
/// (boards Share-OpenPreview, Settings-Accounts, Settings-Sharing).
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: Theme.Layout.statusDotSize, height: Theme.Layout.statusDotSize)
            .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: Theme.Spacing.medium) {
        RingDot()
        RingDot(color: Theme.Colors.hairlineStrong)
        RingDot(color: Theme.Colors.success, size: Theme.Layout.syncDoneMarkSize)
        StatusDot(color: Theme.Colors.success)
    }
    .padding(Theme.Spacing.xxLarge)
    .background(Theme.Colors.card)
}
