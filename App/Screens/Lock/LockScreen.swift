import AppKit
import SwiftUI

/// The lock screen (§10.2): master password, Touch ID and "Use recovery key" (board Lock).
struct LockScreen: View {
    @State private var viewModel: LockViewModel
    @State private var recoveryViewModel: RecoveryResetViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(app: AppViewModel) {
        _viewModel = State(initialValue: app.lockScreen)
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
        .sheet(item: Binding(get: { viewModel.touchIDOffer }, set: { _ in })) { offer in
            TouchIDOfferScreen(viewModel: offer)
        }
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

/// The lock screen content (board Lock): the mark, the headline, and a 360 pt form with the
/// password pill and Unlock, Touch ID, the password-required line and the recovery link, all on
/// the dotted ground.
private struct LockCardView: View {
    @Bindable var viewModel: LockViewModel
    @FocusState private var isPasswordFocused: Bool

    private var passwordLabel: String {
        String(localized: "lock.password.placeholder", defaultValue: "Master password")
    }

    var body: some View {
        ShellCenteredScroll {
            VStack(spacing: Theme.Spacing.xLargePlus) {
                BrandMark(size: Theme.Layout.brandMarkLarge)
                SheetHeader(
                    label: nil,
                    title: String(localized: "lock.headline", defaultValue: "FX Vault is locked."),
                    subtitle: viewModel.subtitle,
                    titleStyle: .display,
                    subtitleStyle: .lead,
                    subtitleSpacing: Theme.Spacing.small,
                    alignment: .center
                )
                form
                    .frame(width: Theme.Layout.lockFormWidth)
                GHStatusRow(status: viewModel.ghStatus)
                    .frame(maxWidth: Theme.Layout.cardWidth)
            }
        }
        .onAppear {
            isPasswordFocused = true
        }
        .onChange(of: viewModel.passwordFocusRequest) {
            isPasswordFocused = true
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            SectionLabel(passwordLabel)
                .accessibilityHidden(true)
            HStack(spacing: Theme.Spacing.small) {
                // An empty prompt: the MASTER PASSWORD label sits above the field, and the title
                // would otherwise show as a mono placeholder. Mono draws evenly spaced bullets.
                SecureField(passwordLabel, text: $viewModel.password, prompt: Text(verbatim: ""))
                    .textContentType(.password)
                    .focused($isPasswordFocused)
                    .disabled(viewModel.isUnlocking)
                    .onSubmit { Task { await viewModel.unlockWithPassword() } }
                    .fxInputField(.pill, isFocused: isPasswordFocused, isMonospaced: true)
                Button {
                    Task { await viewModel.unlockWithPassword() }
                } label: {
                    ShellForwardLabel(title: String(localized: "lock.unlock", defaultValue: "Unlock"))
                }
                .fxButtonStyle(.primary, size: .large)
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canUnlockWithPassword)
            }
            if viewModel.showsTouchIDButton {
                Button {
                    Task { await viewModel.unlockWithTouchID() }
                } label: {
                    Label(String(localized: "lock.touchID", defaultValue: "Unlock with Touch ID"), systemImage: "touchid")
                }
                .fxButtonStyle(.secondary, size: .large, isFullWidth: true)
                .disabled(viewModel.isUnlocking)
            }
            if let error = viewModel.error {
                InlineErrorView(error: error)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
                if viewModel.isUnlocking {
                    ProgressView()
                        .controlSize(.small)
                } else if let title = viewModel.biometricNotice?.title {
                    Text(title)
                        .fxTextStyle(.statusLine)
                        .foregroundStyle(Theme.Colors.subtleText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.small)
                Button(String(localized: "lock.useRecoveryKey", defaultValue: "Use recovery key")) {
                    viewModel.showRecoveryReset()
                }
                .fxLinkButtonStyle()
                .help(String(localized: "lock.forgot", defaultValue: "Forgot password? Use recovery key"))
            }
            .padding(.top, Theme.Spacing.xSmall)
            if let notice = viewModel.biometricNotice {
                LockNoticeView(notice: notice)
            }
        }
    }
}

/// The Touch ID explanation under the lock form (the short reason is the status line above it).
private struct LockNoticeView: View {
    let notice: LockNoticeModel

    var body: some View {
        Label {
            Text(notice.detail)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "touchid")
                .foregroundStyle(Theme.Colors.subtleText)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    if let container = try? AppContainer.preview() {
        LockScreen(app: AppViewModel(container: container))
            .frame(width: Theme.Layout.windowDefaultWidth, height: Theme.Layout.windowDefaultHeight)
    }
}
