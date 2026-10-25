import SwiftUI
import VaultCore

/// First launch (§10.1), boards Main to Touch ID: a centered Welcome, then the Secure phase as one
/// column (phase header and step counter, large title, muted paragraph, fields, footer pills).
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
        Group {
            if viewModel.step == .welcome {
                WelcomeStepView(viewModel: viewModel)
            } else {
                stepColumn
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.ground)
        .animation(Theme.Durations.interactionAnimation, value: viewModel.step)
    }

    /// Board Password to Touch ID: the phase header and the step counter over the step.
    private var stepColumn: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xLargePlus) {
                    HStack {
                        OnboardingPhaseHeader(current: .secure)
                        Spacer(minLength: Theme.Spacing.large)
                        if let number = viewModel.secureStepNumber {
                            StepCounter(current: number, total: viewModel.secureSteps.count)
                        }
                    }
                    Group {
                        switch viewModel.step {
                        case .welcome:
                            EmptyView()
                        case .createPassword:
                            CreatePasswordStepView(viewModel: viewModel)
                        case .recoveryKey:
                            RecoveryKeyStepView(viewModel: viewModel)
                        case .confirmRecoveryKey:
                            ConfirmRecoveryKeyStepView(viewModel: viewModel)
                        case .touchID:
                            TouchIDStepView(viewModel: viewModel)
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
    }
}

/// The three phases of first launch (1.0): the current one in ink, the others subtle.
struct OnboardingPhaseHeader: View {
    enum Phase: CaseIterable {
        case secure, connect, `import`

        var title: String {
            switch self {
            case .secure: String(localized: "onboarding.phase.secure", defaultValue: "Secure")
            case .connect: String(localized: "onboarding.phase.connect", defaultValue: "Connect")
            case .import: String(localized: "onboarding.phase.import", defaultValue: "Import")
            }
        }
    }

    /// Nil on Welcome, where every phase is still ahead.
    let current: Phase?

    var body: some View {
        HStack(spacing: Theme.Spacing.smallMinus) {
            ForEach(Array(Phase.allCases.enumerated()), id: \.offset) { index, phase in
                if index > 0 {
                    Text(verbatim: "·")
                        .foregroundStyle(Theme.Colors.subtleText)
                }
                Text(phase.title)
                    .foregroundStyle(phase == current ? Theme.Colors.ink : Theme.Colors.subtleText)
            }
        }
        .fxTextStyle(.statusLine)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    if let container = try? AppContainer.preview() {
        OnboardingScreen(app: AppViewModel(container: container))
            .frame(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
    }
}
