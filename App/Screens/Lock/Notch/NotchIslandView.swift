import Observation
import SwiftUI

/// What the island shows (boards NotchUnlock, NotchPassword, NotchUnlocked). It never shows
/// names or values.
@Observable
final class NotchIslandModel {
    enum State: Equatable {
        case touchID
        case password
        case unlocked
    }

    let lock: LockViewModel
    /// The screen's notch height; 0 floats the island under the menu bar with all corners round.
    var notchHeight: CGFloat = 0
    var isUnlocked = false
    /// **Use Password**, or the Touch ID prompt's own password fallback.
    var prefersPassword = false
    /// The island's size changed; the panel keeps its top edge where it is.
    @ObservationIgnored var onSizeChange: ((CGSize) -> Void)?

    init(lock: LockViewModel) {
        self.lock = lock
    }

    var state: State {
        if isUnlocked { return .unlocked }
        return lock.showsTouchIDButton && !prefersPassword ? .touchID : .password
    }

    /// A new lock starts on Touch ID again.
    func reset() {
        isUnlocked = false
        prefersPassword = false
    }
}

/// The black island grown out of the notch: Touch ID, the master password, or "Unlocked".
struct NotchIslandView: View {
    @Bindable var model: NotchIslandModel
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // The hardware notch covers this band; the island's content starts under it.
            Color.clear.frame(height: model.notchHeight)
            content
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.top, model.notchHeight > 0 ? Theme.Spacing.small : Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.medium)
        }
        .frame(width: Theme.Layout.islandWidth)
        .background(Theme.Colors.island, in: shape)
        .environment(\.colorScheme, .dark)
        .animation(Theme.Durations.spring, value: model.state)
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            model.onSizeChange?(size)
        }
        .onChange(of: model.lock.passwordFocusRequest) {
            model.prefersPassword = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Island.panel)
    }

    /// Flush with the screen's top edge under a notch: only the lower corners are round.
    private var shape: UnevenRoundedRectangle {
        let radius = Theme.Layout.islandCornerRadius
        let top = model.notchHeight > 0 ? 0 : radius
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: top)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .touchID:
            touchID
        case .password:
            password
        case .unlocked:
            Label(String(localized: "island.unlocked", defaultValue: "Unlocked"), systemImage: "lock.open.fill")
                .fxTextStyle(.headline)
                .foregroundStyle(Theme.Colors.islandInk)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(AccessibilityID.Island.unlocked)
        }
    }

    private var touchID: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Button {
                Task { await model.lock.unlockWithTouchID() }
            } label: {
                HStack(spacing: Theme.Spacing.medium) {
                    Image(systemName: "touchid")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.islandInk)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                        Text(String(localized: "island.locked", defaultValue: "FX Vault is locked"))
                            .fxTextStyle(.headline)
                            .foregroundStyle(Theme.Colors.islandInk)
                        Text(String(localized: "island.touchID", defaultValue: "Touch ID to unlock"))
                            .fxTextStyle(.caption)
                            .foregroundStyle(Theme.Colors.islandMuted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.lock.isUnlocking)
            .accessibilityIdentifier(AccessibilityID.Island.touchID)
            Spacer(minLength: Theme.Spacing.small)
            Button(String(localized: "island.usePassword", defaultValue: "Use Password")) {
                model.prefersPassword = true
            }
            .buttonStyle(.plain)
            .fxTextStyle(.caption)
            .foregroundStyle(Theme.Colors.islandInk)
            .accessibilityIdentifier(AccessibilityID.Island.usePassword)
        }
    }

    private var password: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SecureField(
                String(localized: "island.password", defaultValue: "Master password"),
                text: Bindable(model.lock).password
            )
            .textContentType(.password)
            .focused($isPasswordFocused)
            .disabled(model.lock.isUnlocking)
            .onSubmit { Task { await model.lock.unlockWithPassword() } }
            .fxInputField(.pill, isFocused: isPasswordFocused, isMonospaced: true)
            .accessibilityIdentifier(AccessibilityID.Island.password)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                if model.lock.isUnlocking {
                    ProgressView()
                        .controlSize(.small)
                } else if let status {
                    Text(status)
                        .fxTextStyle(.caption)
                        .foregroundStyle(Theme.Colors.islandMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.small)
                Button(String(localized: "island.recoveryKey", defaultValue: "Recovery Key…")) {
                    model.lock.showRecoveryReset()
                }
                .buttonStyle(.plain)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.islandInk)
                .accessibilityIdentifier(AccessibilityID.Island.recoveryKey)
            }
        }
        .onAppear {
            isPasswordFocused = true
        }
    }

    /// The error of the last attempt, else why the password is needed ("Password required:
    /// After a restart").
    private var status: String? {
        if let error = model.lock.error { return error.title }
        return model.lock.biometricNotice?.title ?? model.lock.biometricNotice?.detail
    }
}
