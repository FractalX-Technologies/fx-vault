import AppKit
import SwiftUI

/// The lock screen (§10.2): master password, Touch ID and "Forgot password? Use recovery key".
struct LockScreen: View {
    @State private var viewModel: LockViewModel
    @State private var recoveryViewModel: RecoveryResetViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(app: AppViewModel) {
        _viewModel = State(initialValue: app.makeLockViewModel())
        _recoveryViewModel = State(initialValue: app.makeRecoveryResetViewModel())
    }

    var body: some View {
        Group {
            if viewModel.isShowingRecoveryReset {
                RecoveryResetScreen(viewModel: recoveryViewModel) {
                    viewModel.recoveryResetDidCancel()
                }
            } else {
                LockCardView(viewModel: viewModel)
            }
        }
        .animation(Theme.Durations.standardAnimation, value: viewModel.isShowingRecoveryReset)
        .task {
            await autoPrompt()
        }
        .onChange(of: scenePhase) {
            Task { await autoPrompt() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await autoPrompt() }
        }
    }

    private func autoPrompt() async {
        await viewModel.autoPromptIfAllowed(isAppActive: NSApp.isActive, isSceneActive: scenePhase == .active)
    }
}

/// The password card of the lock screen.
private struct LockCardView: View {
    @Bindable var viewModel: LockViewModel
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        CenteredCard {
            CardHeader(
                systemImage: "lock.fill",
                title: String(localized: "lock.title", defaultValue: "FX Vault is locked"),
                subtitle: String(localized: "lock.subtitle", defaultValue: "Enter your master password to unlock.")
            )
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                SecureField(
                    String(localized: "lock.password.placeholder", defaultValue: "Master password"),
                    text: $viewModel.password
                )
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .focused($isPasswordFocused)
                .disabled(viewModel.isUnlocking)
                .onSubmit { Task { await viewModel.unlockWithPassword() } }

                if let notice = viewModel.biometricNotice {
                    Text(notice)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = viewModel.error {
                InlineErrorView(error: error)
            }
            HStack {
                if viewModel.showsTouchIDButton {
                    Button {
                        Task { await viewModel.unlockWithTouchID() }
                    } label: {
                        Label(String(localized: "lock.touchID", defaultValue: "Unlock with Touch ID"), systemImage: "touchid")
                    }
                    .disabled(viewModel.isUnlocking)
                }
                Spacer()
                if viewModel.isUnlocking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(String(localized: "lock.unlock", defaultValue: "Unlock")) {
                    Task { await viewModel.unlockWithPassword() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canUnlockWithPassword)
            }
            Divider()
            HStack {
                GHStatusRow(status: viewModel.ghStatus)
                Spacer()
                Button(String(localized: "lock.forgot", defaultValue: "Forgot password? Use recovery key")) {
                    viewModel.showRecoveryReset()
                }
                .buttonStyle(.link)
            }
        }
        .onAppear {
            isPasswordFocused = true
        }
        .onChange(of: viewModel.passwordFocusRequest) {
            isPasswordFocused = true
        }
    }
}

#Preview {
    if let container = try? AppContainer.preview() {
        LockScreen(app: AppViewModel(container: container))
            .frame(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
    }
}
