import AppKit
import SwiftUI

/// The import sheet's paste editor: the shared ``SecretTextView`` (no substitutions, no undo,
/// secure event input while focused) that can take keyboard focus as the sheet opens, so
/// "Paste Multiple…" is one ⌘V away.
///
/// It has its own coordinator: the whole `.env` text is not one value, so the D32 commit rule
/// of ``SecretValueEditor`` (strip trailing line breaks when focus leaves) does not apply, and
/// nothing is written back once the view is being torn down.
struct EnvPasteEditorView: NSViewRepresentable {
    @Binding var text: String
    let focusesOnAppear: Bool

    func makeCoordinator() -> EnvPasteEditorCoordinator {
        EnvPasteEditorCoordinator(text: $text)
    }

    func makeNSView(context: Context) -> EnvPasteEditorContainerView {
        let scrollView = SecretTextView.makeScrollableEditor()
        if let textView = scrollView.documentView as? SecretTextView {
            textView.delegate = context.coordinator
            textView.string = text
        }
        return EnvPasteEditorContainerView(scrollView: scrollView, focusesOnWindow: focusesOnAppear)
    }

    func updateNSView(_ container: EnvPasteEditorContainerView, context: Context) {
        context.coordinator.text = $text
        guard let textView = container.textView, textView.string != text else { return }
        textView.string = text
    }

    /// Detaches the editor from the view model before AppKit removes it (and it resigns first
    /// responder), and empties it, so the pasted text never flows back after `discard()`.
    static func dismantleNSView(_ container: EnvPasteEditorContainerView, coordinator: EnvPasteEditorCoordinator) {
        coordinator.detach()
        if let textView = container.textView {
            textView.delegate = nil
            textView.string = ""
            textView.endSecureEventInput()
        }
    }
}

/// Forwards every edit of the paste editor to the binding as typed; nothing else.
final class EnvPasteEditorCoordinator: NSObject, NSTextViewDelegate {
    /// The view model's text, or nil once the editor was dismantled.
    var text: Binding<String>?

    init(text: Binding<String>) {
        self.text = text
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        text?.wrappedValue = textView.string
    }

    /// Stops all writes to the binding.
    func detach() {
        text = nil
    }
}

/// Hosts the editor's scroll view and focuses the text view once it is in a window.
final class EnvPasteEditorContainerView: NSView {
    private let scrollView: NSScrollView
    private var focusesOnWindow: Bool

    init(scrollView: NSScrollView, focusesOnWindow: Bool) {
        self.scrollView = scrollView
        self.focusesOnWindow = focusesOnWindow
        super.init(frame: .zero)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var textView: SecretTextView? {
        scrollView.documentView as? SecretTextView
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusesOnWindow, window != nil else { return }
        focusesOnWindow = false
        // After SwiftUI finished installing the sheet's own first responder.
        Task { @MainActor [weak self] in
            guard let self, let window, let textView else { return }
            window.makeFirstResponder(textView)
        }
    }
}
