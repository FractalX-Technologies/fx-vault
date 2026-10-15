import SwiftUI
import VaultCore

/// First launch (§10.1), board Onboarding: a step column on the left (mono step counter, large
/// title, muted paragraph, fields, footer pills) and a side panel listing every step.
struct OnboardingScreen: View {
    @State private var viewModel: OnboardingViewModel

    init(app: AppViewModel) {
        _viewModel = State(initialValue: app.makeOnboardingViewModel())
    }

    /// Shows an existing view model (previews and the visual snapshot tests).
    init(viewModel: OnboardingViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xLargePlus) {
                        StepCounter(current: currentStepNumber, total: viewModel.visibleSteps.count)
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
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .padding(.vertical, Theme.Spacing.huge)
                    .padding(.horizontal, Theme.Spacing.xHuge)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            OnboardingStepsPanel(
                steps: viewModel.visibleSteps,
                current: viewModel.step,
                ghStatus: viewModel.ghStatus
            )
        }
        .background(Theme.Colors.ground)
        .animation(Theme.Durations.interactionAnimation, value: viewModel.step)
    }

    private var currentStepNumber: Int {
        (viewModel.visibleSteps.firstIndex(of: viewModel.step) ?? 0) + 1
    }
}

/// The right-hand panel: every visible step as a mono label over a short value; the current
/// step's label in the brand color, the other labels subtle; done and current values in ink,
/// upcoming values subtle (board Onboarding). `faintText` never carries information here.
private struct OnboardingStepsPanel: View {
    let steps: [OnboardingViewModel.Step]
    let current: OnboardingViewModel.Step
    let ghStatus: GHStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.largePlus) {
            SectionLabel(String(localized: "onboarding.panel.title", defaultValue: "Setup"))
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    SectionLabel("\(StepCounter.padded(index + 1)) \(step.panelTitle)", color: labelColor(for: step))
                    Text(value(for: step))
                        .fxTextStyle(.body)
                        .foregroundStyle(step > current ? Theme.Colors.subtleText : Theme.Colors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.bottom, Theme.Spacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    HairlineDivider()
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.huge)
        .padding(.horizontal, Theme.Spacing.xxLarge)
        .frame(width: Theme.Layout.onboardingSidePanelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.surface)
        .overlay(alignment: .leading) {
            HairlineDivider(axis: .vertical)
        }
    }

    private func labelColor(for step: OnboardingViewModel.Step) -> Color {
        step == current ? Theme.Colors.brand : Theme.Colors.subtleText
    }

    private func value(for step: OnboardingViewModel.Step) -> String {
        if step == current {
            return String(localized: "onboarding.panel.current", defaultValue: "In progress")
        }
        if step < current {
            if step == .welcome, case .ready(let version, _) = ghStatus {
                return String(localized: "onboarding.panel.welcome.gh", defaultValue: "gh \(version)")
            }
            return String(localized: "onboarding.panel.done", defaultValue: "Done")
        }
        return step.panelUpcomingValue
    }
}

private extension OnboardingViewModel.Step {
    /// The step's name in the side panel (uppercased by the section label).
    var panelTitle: String {
        switch self {
        case .welcome:
            String(localized: "onboarding.panel.welcome", defaultValue: "Welcome")
        case .createPassword:
            String(localized: "onboarding.panel.password", defaultValue: "Password")
        case .recoveryKey:
            String(localized: "onboarding.panel.recoveryKey", defaultValue: "Recovery key")
        case .confirmRecoveryKey:
            String(localized: "onboarding.panel.confirm", defaultValue: "Confirm")
        case .touchID:
            String(localized: "onboarding.panel.touchID", defaultValue: "Touch ID")
        case .done:
            String(localized: "onboarding.panel.ready", defaultValue: "Ready")
        }
    }

    /// What an upcoming step involves.
    var panelUpcomingValue: String {
        switch self {
        case .welcome:
            String(localized: "onboarding.panel.welcome.next", defaultValue: "GitHub CLI check")
        case .createPassword:
            String(localized: "onboarding.panel.password.next", defaultValue: "Encrypts the vault")
        case .recoveryKey:
            String(localized: "onboarding.panel.recoveryKey.next", defaultValue: "Shown once")
        case .confirmRecoveryKey:
            String(
                localized: "onboarding.panel.confirm.next",
                defaultValue: "\(Limits.recoveryConfirmGroupCount) groups to re-enter"
            )
        case .touchID:
            String(localized: "onboarding.panel.touchID.next", defaultValue: "Optional")
        case .done:
            String(localized: "onboarding.panel.ready.next", defaultValue: "Open your vault")
        }
    }
}

#Preview {
    if let container = try? AppContainer.preview() {
        OnboardingScreen(app: AppViewModel(container: container))
            .frame(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
    }
}
