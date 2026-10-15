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
    @State private var didStripTrailingNewlines = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            SecretTextViewRepresentable(text: $value) { stripped in
                didStripTrailingNewlines = stripped
            }
            .frame(minHeight: Theme.Layout.secretEditorMinHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .strokeBorder(Theme.Colors.textSecondary.opacity(Theme.Opacity.chipBackground))
            )
            .accessibilityLabel(String(localized: "secretEditor.accessibilityLabel", defaultValue: "Value"))

            if didStripTrailingNewlines {
                Label(Self.strippedNotice, systemImage: "return")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.warning)
            }
            if Self.looksLikeKey(value) {
                Label(Self.keyHint, systemImage: "key")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
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
    let onCommit: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SecretTextView.makeScrollableEditor()
        if let textView = scrollView.documentView as? SecretTextView {
            textView.delegate = context.coordinator
            textView.string = text
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView.documentView as? SecretTextView)?.endSecureEventInput()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let onCommit: (Bool) -> Void

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
        textView.configureForSecrets()
        scrollView.documentView = textView
        return scrollView
    }

    /// Turns off everything that could change the bytes or keep a copy (§5.11).
    func configureForSecrets() {
        isRichText = false
        importsGraphics = false
        allowsUndo = false
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
        if #available(macOS 15.0, *) {
            writingToolsBehavior = .none
        }
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textColor = .labelColor
        drawsBackground = false
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            beginSecureEventInput()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            endSecureEventInput()
        }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            endSecureEventInput()
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
