import SwiftUI

/// The shape of a FractalX input (docs/DESIGN.md, "Inputs").
enum FXInputShape: Sendable {
    /// Capsule. Single inputs paired with a pill button (lock: password + Unlock), search.
    case pill
    /// 12 pt corners. Forms and stacked fields (onboarding, editors, settings).
    case rounded
}

private struct FXInputFieldModifier: ViewModifier {
    let shape: FXInputShape
    let isFocused: Bool
    let isInvalid: Bool
    let isMonospaced: Bool

    func body(content: Content) -> some View {
        switch shape {
        case .pill:
            styled(content, in: .pill)
        case .rounded:
            styled(content, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
    }

    private func styled(_ content: Content, in inputShape: some InsettableShape) -> some View {
        content
            .textFieldStyle(.plain)
            .font(isMonospaced ? Theme.Typography.monospaced : Theme.Typography.body)
            .foregroundStyle(Theme.Colors.ink)
            .padding(.horizontal, Theme.Spacing.large)
            .frame(minHeight: Theme.Layout.inputHeight)
            .background(Theme.Colors.card, in: inputShape)
            .overlay(inputShape.strokeBorder(borderColor, lineWidth: borderWidth))
            .animation(Theme.Durations.interactionAnimation, value: isFocused)
    }

    private var borderColor: Color {
        if isInvalid { return Theme.Colors.danger }
        return isFocused ? Theme.Colors.brand : Theme.Colors.hairlineStrong
    }

    private var borderWidth: CGFloat {
        isFocused || isInvalid ? Theme.Layout.focusRingWidth : Theme.Stroke.hairline
    }
}

extension View {
    /// Styles a `TextField` or `SecureField` as a FractalX input: card fill, hairline-strong
    /// border, 44 pt tall; brand border while `isFocused`, danger while `isInvalid`. Bind
    /// `isFocused` to the caller's `@FocusState` (the modifier cannot observe focus itself).
    ///
    /// ```swift
    /// @FocusState private var focused: Bool
    /// SecureField(String(localized: "lock.password", defaultValue: "Master password"), text: $password)
    ///     .focused($focused)
    ///     .fxInputField(.pill, isFocused: focused)
    /// ```
    func fxInputField(_ shape: FXInputShape = .rounded, isFocused: Bool = false, isInvalid: Bool = false, isMonospaced: Bool = false) -> some View {
        modifier(FXInputFieldModifier(shape: shape, isFocused: isFocused, isInvalid: isInvalid, isMonospaced: isMonospaced))
            .focusEffectDisabled()
    }
}

/// A labelled FractalX text field that tracks its own focus: a ``SectionLabel`` above the
/// input (mockup Lock and Onboarding). Use ``View/fxInputField(_:isFocused:isInvalid:isMonospaced:)``
/// directly when the screen manages focus.
///
/// ```swift
/// FXTextField(
///     label: String(localized: "createRepo.name", defaultValue: "Name"),
///     text: $viewModel.name,
///     prompt: String(localized: "createRepo.name.prompt", defaultValue: "my-service"),
///     isMonospaced: true
/// )
/// FXTextField(label: passwordLabel, text: $password, isSecure: true, shape: .pill)
/// ```
struct FXTextField: View {
    let label: String?
    @Binding var text: String
    var prompt: String?
    var isSecure = false
    var shape: FXInputShape = .rounded
    var isInvalid = false
    var isMonospaced = false
    @FocusState private var isFocused: Bool

    init(
        label: String?,
        text: Binding<String>,
        prompt: String? = nil,
        isSecure: Bool = false,
        shape: FXInputShape = .rounded,
        isInvalid: Bool = false,
        isMonospaced: Bool = false
    ) {
        self.label = label
        self._text = text
        self.prompt = prompt
        self.isSecure = isSecure
        self.shape = shape
        self.isInvalid = isInvalid
        self.isMonospaced = isMonospaced
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.mediumMinus) {
            if let label {
                SectionLabel(label)
                    .accessibilityHidden(true)
            }
            field
                .focused($isFocused)
                // Secure fields draw Geist Mono bullets at a fixed advance (evenly spaced, like the
                // masked values in the table).
                .fxInputField(shape, isFocused: isFocused, isInvalid: isInvalid, isMonospaced: isMonospaced || isSecure)
                .accessibilityLabel(label ?? prompt ?? "")
        }
    }

    @ViewBuilder
    private var field: some View {
        // A placeholder sentence stays in Geist Sans, even in a secure field (drawn in mono). A
        // secure field shows its label as the placeholder when there is no prompt.
        let promptFont = isMonospaced ? Theme.Typography.monospaced : Theme.Typography.body
        let promptText = prompt.map { Text($0).font(promptFont).foregroundStyle(Theme.Colors.subtleText) }
        if isSecure {
            let securePrompt = Text(prompt ?? label ?? "").font(promptFont).foregroundStyle(Theme.Colors.subtleText)
            SecureField(label ?? "", text: $text, prompt: securePrompt)
        } else {
            TextField(label ?? "", text: $text, prompt: promptText)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
        FXTextField(label: "Name", text: .constant("STRIPE_SECRET_KEY"), isMonospaced: true)
        FXTextField(label: "Master password", text: .constant("correct-horse"), isSecure: true, shape: .pill)
        FXTextField(label: "Invalid", text: .constant(""), isInvalid: true)
    }
    .frame(width: Theme.Layout.lockFormWidth)
    .padding(Theme.Spacing.xxLarge)
    .background(Theme.Colors.ground)
}
