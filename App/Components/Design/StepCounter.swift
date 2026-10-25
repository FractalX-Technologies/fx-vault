import SwiftUI

/// The onboarding step counter in SF Mono (mockup Onboarding): `02 / 05`, the slash faint.
///
/// ```swift
/// StepCounter(current: viewModel.stepNumber, total: OnboardingViewModel.stepCount)
/// ```
struct StepCounter: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.smallMinus) {
            Text(Self.padded(current))
                .foregroundStyle(Theme.Colors.subtleText)
            Text(verbatim: "/")
                .foregroundStyle(Theme.Colors.faintText)
            Text(Self.padded(total))
                .foregroundStyle(Theme.Colors.subtleText)
        }
        .fxTextStyle(.monoCounter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(current: current, total: total))
    }

    /// Two digits at least: 2 → "02", 12 → "12".
    static func padded(_ number: Int) -> String {
        number.formatted(.number.precision(.integerLength(2...)).grouping(.never))
    }

    /// "02 / 05" as one string (tests, logs).
    static func text(current: Int, total: Int) -> String {
        "\(padded(current)) / \(padded(total))"
    }

    static func accessibilityLabel(current: Int, total: Int) -> String {
        String(localized: "stepCounter.accessibility", defaultValue: "Step \(current) of \(total)")
    }
}

#Preview {
    StepCounter(current: 2, total: 5)
        .padding(Theme.Spacing.xxLarge)
}
