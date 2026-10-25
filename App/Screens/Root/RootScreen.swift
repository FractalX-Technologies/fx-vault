import SwiftUI

/// Chooses the screen for the current vault phase (§10). Changing ``AppViewModel/phase`` to
/// `.locked` removes the onboarding and main screens, and with them every value on screen. After
/// unlock, ``GHSetupScreen`` replaces the main window while gh needs attention (§10.3); right
/// after onboarding, ``ConnectScreen`` comes first.
struct RootScreen: View {
    let viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            .frame(
                minWidth: Theme.Layout.windowMinWidth,
                maxWidth: .infinity,
                minHeight: Theme.Layout.windowMinHeight,
                maxHeight: .infinity
            )
            .background(Theme.Colors.ground)
            .background(WindowAccessor { window in
                viewModel.attachMainWindow(window)
            })
            .onAppear {
                // Lets the app delegate bring the window back for a `.fxvault` file (§10 Scenes).
                viewModel.setMainWindowOpener { [openWindow] in
                    openWindow(id: SceneID.main)
                }
            }
            .onOpenURL { url in
                viewModel.openShareFiles([url])
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .onboarding:
            OnboardingScreen(app: viewModel)
                .id(viewModel.lockCount)
        case .locked:
            LockScreen(app: viewModel)
                .id(viewModel.lockCount)
        case .unlocked:
            if viewModel.showsGHSetup {
                GHSetupScreen(app: viewModel)
            } else if viewModel.isFirstConnectPending {
                ConnectScreen(app: viewModel)
            } else {
                MainScreen(app: viewModel)
            }
        }
    }
}

/// Shown when the vault database cannot be opened at launch. FX Vault never falls back to an
/// empty vault, which could make the user create a second vault over the first.
struct StartupFailureScreen: View {
    let error: ErrorPresentationModel

    var body: some View {
        EmptyStateView(
            systemImage: "externaldrive.badge.exclamationmark",
            title: String(localized: "startup.failed.title", defaultValue: "FX Vault could not open your vault"),
            message: String(
                localized: "startup.failed.message",
                defaultValue: "Check that your user account can read Application Support/FX Vault, then quit and reopen FX Vault. \(error.message)"
            )
        ) {
            Button(String(localized: "startup.failed.quit", defaultValue: "Quit FX Vault")) {
                NSApp.terminate(nil)
            }
            .fxButtonStyle(.primary, size: .large)
        }
        .frame(minWidth: Theme.Layout.windowMinWidth, minHeight: Theme.Layout.windowMinHeight)
        .background(Theme.Colors.ground)
    }
}

#Preview {
    if let container = try? AppContainer.preview() {
        RootScreen(viewModel: AppViewModel(container: container))
    }
}
