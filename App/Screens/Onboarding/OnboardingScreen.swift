import SwiftUI

/// First launch (§10.1). One card, one step at a time, with a progress indicator.
struct OnboardingScreen: View {
    @State private var viewModel: OnboardingViewModel

    init(app: AppViewModel) {
        _viewModel = State(initialValue: app.makeOnboardingViewModel())
    }

    var body: some View {
        CenteredCard {
            StepIndicator(steps: viewModel.visibleSteps, current: viewModel.step)
            Group {
                switch viewModel.step {
                case .welcome:
                    WelcomeStepView(viewModel: viewModel)
                case .createPassword:
                    CreatePasswordStepView(viewModel: viewModel)
                case .recoveryKey:
                    RecoveryKeyStepView(viewModel: viewModel)
                case .confirmRecoveryKey:
                    ConfirmRecoveryKeyStepView(viewModel: viewModel)
                case .touchID:
                    TouchIDStepView(viewModel: viewModel)
                case .done:
                    DoneStepView(viewModel: viewModel)
                }
            }
            .transition(.opacity)
            if let error = viewModel.error {
                InlineErrorView(error: error)
            }
        }
        .animation(Theme.Durations.standardAnimation, value: viewModel.step)
    }
}

/// Dots for the visible onboarding steps.
private struct StepIndicator: View {
    let steps: [OnboardingViewModel.Step]
    let current: OnboardingViewModel.Step

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            ForEach(steps, id: \.self) { step in
                Circle()
                    .fill(step <= current ? Theme.Colors.accent : Theme.Colors.textSecondary.opacity(Theme.Opacity.chipBackground))
                    .frame(width: Theme.Layout.stepIndicatorDotSize, height: Theme.Layout.stepIndicatorDotSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            localized: "onboarding.progress.accessibility",
            defaultValue: "Step \((steps.firstIndex(of: current) ?? 0) + 1) of \(steps.count)"
        ))
    }
}

#Preview {
    if let container = try? AppContainer.preview() {
        OnboardingScreen(app: AppViewModel(container: container))
            .frame(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
    }
}
