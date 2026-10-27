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
    /// The hardware notch's width, where the island grows from; 0 without a notch.
    var notchWidth: CGFloat = 0
    /// Grown out of the notch; false draws the notch alone. Each show grows it again.
    var isRevealed = false
    var isUnlocked = false
    /// **Use Password**, or the Touch ID prompt's own password fallback.
    var prefersPassword = false
    /// The quick vault's shortcut asked while locked: the island says so and is the quick
    /// vault's width (board QuickVault-Locked).
    var opensQuickVault = false
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
        isRevealed = false
        isUnlocked = false
        prefersPassword = false
        opensQuickVault = false
    }

    var width: CGFloat {
        opensQuickVault ? Theme.Layout.quickVaultWidth : Theme.Layout.islandWidth
    }
}

/// The black island grown out of the notch: Touch ID, the master password, or "Unlocked".
struct NotchIslandView: View {
    @Bindable var model: NotchIslandModel
    @FocusState private var isPasswordFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            content
            if model.opensQuickVault, model.state != .unlocked {
                // Dimmed until the unlock: no place, name or count shows while locked.
                QuickVaultSearchField.locked
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.top, model.notchHeight > 0 ? Theme.Spacing.small : Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.medium)
        .opacity(model.isRevealed ? 1 : 0)
        .animation(
            model.isRevealed ? Theme.Durations.islandContentReveal : Theme.Durations.interactionAnimation,
            value: model.isRevealed
        )
        .notchIsland(
            notchHeight: model.notchHeight,
            width: model.width,
            // With Reduce Motion the outline stays whole and only the content fades.
            reveal: reduceMotion || model.isRevealed ? 1 : 0,
            notchWidth: model.notchWidth
        )
        .animation(model.isRevealed ? Theme.Durations.islandReveal : Theme.Durations.islandCollapse, value: model.isRevealed)
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

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .touchID:
            touchID
        case .password:
            password
        case .unlocked:
            Label {
                Text(String(localized: "island.unlocked", defaultValue: "Unlocked"))
            } icon: {
                // The finger was accepted: the padlock opens with a bounce.
                Image(systemName: "lock.open.fill")
                    .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : model.isUnlocked)
            }
            .fxTextStyle(.headline)
            .foregroundStyle(Theme.Colors.islandInk)
            .frame(maxWidth: .infinity)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
            .accessibilityIdentifier(AccessibilityID.Island.unlocked)
        }
    }

    private var touchID: some View {
        HStack(spacing: Theme.Spacing.medium) {
            Button {
                Task { await model.lock.unlockWithTouchID() }
            } label: {
                HStack(spacing: Theme.Spacing.medium) {
                    // The brand's dot grid for the quick vault, the fingerprint beside its caption.
                    Group {
                        if model.opensQuickVault {
                            Image(systemName: Theme.Symbols.menuBar)
                                .font(Theme.Typography.title)
                        } else {
                            Image(systemName: "touchid")
                                .font(Theme.Typography.title)
                        }
                    }
                    .foregroundStyle(Theme.Colors.islandInk)
                    // While Touch ID checks the finger, the glyph swells a little.
                    .scaleEffect(model.lock.isUnlocking && !reduceMotion ? 1.15 : 1)
                    .animation(Theme.Durations.spring, value: model.lock.isUnlocking)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                        Text(String(localized: "island.locked", defaultValue: "FX Vault is locked"))
                            .fxTextStyle(.headline)
                            .foregroundStyle(Theme.Colors.islandInk)
                        if model.opensQuickVault {
                            Label {
                                Text(QuickVaultCopy.touchIDToOpen)
                            } icon: {
                                Image(systemName: "touchid")
                                    .font(Theme.Typography.caption)
                            }
                            .fxTextStyle(.caption)
                            .foregroundStyle(Theme.Colors.islandMuted)
                        } else {
                            Text(String(localized: "island.touchID", defaultValue: "Touch ID to unlock"))
                                .fxTextStyle(.caption)
                                .foregroundStyle(Theme.Colors.islandMuted)
                        }
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

extension View {
    /// The black island grown out of the notch (the lock island, the quick vault): a band the
    /// hardware notch covers, then the content, `width` wide. Under a notch it is flush with the
    /// screen's top edge, so only its lower corners are round.
    func notchIsland(notchHeight: CGFloat, width: CGFloat, reveal: CGFloat = 1, notchWidth: CGFloat = 0) -> some View {
        let radius = Theme.Layout.islandCornerRadius
        let top = notchHeight > 0 ? 0 : radius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: top
        )
        return VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            self
        }
        .frame(width: width)
        .background {
            IslandGlass(notchHeight: notchHeight)
                .clipShape(shape)
        }
        // `reveal` grows it out of the notch (the lock island); 1 draws it whole.
        .clipShape(NotchRevealShape(
            progress: reveal,
            startWidth: notchWidth,
            startHeight: notchHeight,
            topRadius: top,
            startRadius: Theme.Layout.notchCornerRadius,
            radius: radius
        ))
        .environment(\.colorScheme, .dark)
    }
}

/// The island's ground (1.0.2): the desktop blurred under black, like the main window's glass;
/// solid in the band beside the hardware notch, so the island still reads as its continuation.
private struct IslandGlass: View {
    let notchHeight: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .top) {
            BehindWindowBlur()
            Theme.Colors.island.opacity(WindowGlass.opacity(WindowGlass.island, reduceTransparency: reduceTransparency))
            VStack(spacing: 0) {
                Theme.Colors.island
                    .frame(height: notchHeight)
                LinearGradient(colors: [Theme.Colors.island, Theme.Colors.island.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Theme.Spacing.large)
            }
        }
    }
}
