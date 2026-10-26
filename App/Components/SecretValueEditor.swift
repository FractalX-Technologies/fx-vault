import AppKit
import Carbon
import SwiftUI
import VaultCore

/// Multi-line entry for secret and variable values (§5.11, D32).
///
/// - An `NSTextView` with every substitution, correction, completion, prediction, Writing Tools
///   and undo turned off, so the stored bytes are exactly the typed or pasted bytes.
/// - Secure event input is on while the editor has focus (other processes cannot read keys).
/// - On commit (focus leaves the editor) trailing CR/LF are stripped, because `gh secret set`
///   and `gh variable set` strip them anyway, and a notice says so. SSH and PEM keys get a hint.
struct SecretValueEditor: View {
    @Binding var value: String
    /// Takes the keyboard when shown (Set value… in the notes editor, 1.0 N2).
    var focusesOnAppear = false
    @State private var didStripTrailingNewlines = false
    @State private var isFocused = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SecretTextViewRepresentable(text: $value, focusesOnAppear: focusesOnAppear) { stripped in
                didStripTrailingNewlines = stripped
            } onFocusChange: { focused in
                isFocused = focused
            }
            .padding(.horizontal, Theme.Spacing.xSmall)
            .padding(.vertical, Theme.Spacing.xSmall)
            .frame(minHeight: Theme.Layout.secretEditorMinHeight)
            .background(Theme.Colors.card, in: Self.shape)
            .clipShape(Self.shape)
            .overlay(Self.shape.strokeBorder(
                Self.borderColor(isFocused: isFocused && isEnabled),
                lineWidth: Self.borderWidth(isFocused: isFocused && isEnabled)
            ))
            .opacity(isEnabled ? 1 : Theme.Opacity.disabled)
            .animation(Theme.Durations.interactionAnimation, value: isFocused)
            .accessibilityLabel(String(localized: "secretEditor.accessibilityLabel", defaultValue: "Value"))

            if didStripTrailingNewlines {
                Label(Self.strippedNotice, systemImage: "return")
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if Self.looksLikeKey(value) {
                Label(Self.keyHint, systemImage: "key")
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Framed like a rounded FractalX input (`.fxInputField(.rounded)`): 12 pt corners.
    private static let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)

    // MARK: - Frame (pure)

    /// Hairline-strong at rest; the 2 pt brand ring while the editor has focus.
    static func borderColor(isFocused: Bool) -> Color {
        isFocused ? Theme.Colors.brand : Theme.Colors.hairlineStrong
    }

    static func borderWidth(isFocused: Bool) -> CGFloat {
        isFocused ? Theme.Layout.focusRingWidth : Theme.Stroke.hairline
    }

    // MARK: - Commit rules (pure, tested)

    /// The committed form of `text`: trailing CR/LF removed (D32).
    static func committedValue(_ text: String) -> (value: String, didStripTrailingNewlines: Bool) {
        let stripped = ValueNormalizer.strippingTrailingNewlines(text)
        return (stripped, stripped.utf8.count != text.utf8.count)
    }

    private static let keyMarkers = ["-----BEGIN ", "ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-"]

    /// True for values that look like an SSH or PEM key (they lose their final newline on GitHub).
    static func looksLikeKey(_ text: String) -> Bool {
        keyMarkers.contains { text.hasPrefix($0) || text.contains("\n\($0)") }
    }

    static var strippedNotice: String {
        String(
            localized: "secretEditor.notice.strippedNewlines",
            defaultValue: "Trailing line breaks were removed. GitHub removes them too, so FX Vault stores the value as GitHub will."
        )
    }

    static var keyHint: String {
        String(
            localized: "secretEditor.hint.key",
            defaultValue: "GitHub stores keys without the final newline. Workflows usually add it back, for example: echo \"$KEY\" > key"
        )
    }
}

/// The AppKit text view behind ``SecretValueEditor``.
struct SecretTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    var focusesOnAppear = false
    let onCommit: (Bool) -> Void
    /// Called when the text view gains (`true`) or loses (`false`) first responder.
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SecretTextView.makeScrollableEditor()
        if let textView = scrollView.documentView as? SecretTextView {
            textView.delegate = context.coordinator
            textView.string = text
            textView.focusesWhenShown = focusesOnAppear
            textView.onFirstResponderChange = { [coordinator = context.coordinator] focused in
                coordinator.focusChanged(focused)
            }
        }
        context.coordinator.onFocusChange = onFocusChange
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onFocusChange = onFocusChange
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView.documentView as? SecretTextView)?.endSecureEventInput()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let onCommit: (Bool) -> Void
        var onFocusChange: (Bool) -> Void = { _ in }

        init(text: Binding<String>, onCommit: @escaping (Bool) -> Void) {
            self.text = text
            self.onCommit = onCommit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            commit(textView)
        }

        /// Reports focus after the current AppKit event, never during a SwiftUI update.
        func focusChanged(_ focused: Bool) {
            Task { @MainActor [weak self] in
                self?.onFocusChange(focused)
            }
        }

        /// Applies the D32 commit rule to the view and the binding.
        func commit(_ textView: NSTextView) {
            let committed = SecretValueEditor.committedValue(textView.string)
            if committed.didStripTrailingNewlines {
                textView.string = committed.value
            }
            text.wrappedValue = committed.value
            onCommit(committed.didStripTrailingNewlines)
        }
    }
}

/// An `NSTextView` that never rewrites what the user types and keeps secure event input on
/// while it is first responder.
final class SecretTextView: NSTextView {
    /// True while this view holds a secure event input request.
    private(set) var hasSecureEventInput = false
    /// Observes first-responder changes (the SwiftUI frame draws its focus ring from it).
    var onFirstResponderChange: ((Bool) -> Void)?
    /// Becomes first responder once it is in a window.
    var focusesWhenShown = false

    /// A scroll view holding a configured ``SecretTextView``.
    static func makeScrollableEditor() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        let textView = SecretTextView(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: Theme.Spacing.small, height: Theme.Spacing.small)
        // On the text view itself: a SwiftUI identifier stops at the hosting scroll view.
        textView.setAccessibilityIdentifier(AccessibilityID.ItemEditor.value)
        textView.configureForSecrets()
        scrollView.documentView = textView
        return scrollView
    }

    /// Turns off everything that could change the bytes or keep a copy (§5.11).
    func configureForSecrets() {
        isRichText = false
        allowsUndo = false
        turnOffTextServices()
        font = Theme.Typography.nsMonospaced
        textColor = .labelColor
        drawsBackground = false
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            beginSecureEventInput()
            onFirstResponderChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            endSecureEventInput()
            onFirstResponderChange?(false)
        }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            endSecureEventInput()
            return
        }
        if focusesWhenShown {
            focusesWhenShown = false
            window.makeFirstResponder(self)
        }
    }

    func beginSecureEventInput() {
        guard !hasSecureEventInput else { return }
        EnableSecureEventInput()
        hasSecureEventInput = true
    }

    func endSecureEventInput() {
        guard hasSecureEventInput else { return }
        DisableSecureEventInput()
        hasSecureEventInput = false
    }
}

extension NSTextView {
    /// Substitutions, spelling and grammar, completion, detection, prediction, Writing Tools,
    /// pictures and the font, ruler and find panels: none may change typed or pasted bytes
    /// (§5.11; the notes editor, anton D3).
    func turnOffTextServices() {
        importsGraphics = false
        allowsImageEditing = false
        usesFindBar = false
        usesFontPanel = false
        usesRuler = false
        smartInsertDeleteEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        inlinePredictionType = .no
        writingToolsBehavior = .none
    }
}
