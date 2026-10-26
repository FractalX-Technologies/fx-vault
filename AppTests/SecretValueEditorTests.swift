import AppKit
import Carbon
import SwiftUI
import Testing
@testable import FXVault

@MainActor
@Suite("SecretValueEditor")
struct SecretValueEditorTests {
    /// Holds the binding's value.
    private final class Box {
        var text = ""
        var commits: [Bool] = []
    }

    private func makeEditor() -> (SecretTextView, SecretTextViewRepresentable.Coordinator, Box) {
        let box = Box()
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        let coordinator = SecretTextViewRepresentable.Coordinator(text: binding) { box.commits.append($0) }
        let scrollView = SecretTextView.makeScrollableEditor()
        let textView = scrollView.documentView as? SecretTextView ?? SecretTextView(frame: .zero)
        textView.delegate = coordinator
        return (textView, coordinator, box)
    }

    @Test func quotesDashesAndTabsRoundTripByteForByte() throws {
        let (textView, coordinator, box) = makeEditor()
        let typed = "\"--'\t"
        for character in typed {
            textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(Array(box.text.utf8) == Array(typed.utf8))
        #expect(Array(textView.string.utf8) == Array(typed.utf8))

        coordinator.commit(textView)
        #expect(Array(box.text.utf8) == Array(typed.utf8))
        #expect(box.commits.last == false, "commits: \(box.commits)")
    }

    @Test func pastedSmartCharactersAreKeptAsIs() {
        let (textView, coordinator, box) = makeEditor()
        let pasted = "a \u{201C}b\u{201D} -- c... (c) 1/2"
        textView.insertText(pasted, replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        #expect(Array(box.text.utf8) == Array(pasted.utf8))
    }

    @Test func trailingCRLFIsStrippedWithNotice() {
        let (textView, coordinator, box) = makeEditor()
        textView.string = "-----BEGIN KEY-----\nabc\n-----END KEY-----\r\n"
        coordinator.commit(textView)
        #expect(box.text == "-----BEGIN KEY-----\nabc\n-----END KEY-----")
        #expect(textView.string == box.text)
        #expect(box.commits == [true])
        #expect(SecretValueEditor.looksLikeKey(box.text))
    }

    @Test func committedValueRule() {
        #expect(SecretValueEditor.committedValue("v\r\n\n") == ("v", true))
        #expect(SecretValueEditor.committedValue("v\n x") == ("v\n x", false))
        #expect(SecretValueEditor.committedValue("\r\n") == ("", true))
        #expect(!SecretValueEditor.looksLikeKey("plain"))
        #expect(SecretValueEditor.looksLikeKey("ssh-ed25519 AAAA user-a@example"))
    }

    @Test func substitutionsUndoAndWritingToolsAreOff() {
        let (textView, _, _) = makeEditor()
        #expect(!textView.allowsUndo)
        #expect(!textView.isRichText)
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isContinuousSpellCheckingEnabled)
        #expect(!textView.isGrammarCheckingEnabled)
        #expect(!textView.isAutomaticTextCompletionEnabled)
        #expect(!textView.isAutomaticLinkDetectionEnabled)
        #expect(!textView.isAutomaticDataDetectionEnabled)
        #expect(!textView.smartInsertDeleteEnabled)
        #expect(textView.inlinePredictionType == .no)
        #expect(textView.writingToolsBehavior == NSWritingToolsBehavior.none)
        #expect(textView.undoManager == nil || !textView.allowsUndo)
    }

    /// Set value… in the notes editor (1.0 N2) opens with the keyboard in its field, once: a later
    /// move between windows leaves the focus where the user put it.
    @Test func aFieldThatFocusesWhenShownTakesTheKeyboardOnce() {
        let (textView, _, _) = makeEditor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        textView.focusesWhenShown = true
        window.contentView?.addSubview(textView)
        #expect(window.firstResponder === textView)
        #expect(!textView.focusesWhenShown)

        let plain = SecretTextView.makeScrollableEditor().documentView
        window.makeFirstResponder(nil)
        if let plain {
            window.contentView?.addSubview(plain)
        }
        #expect(window.firstResponder !== plain, "only a field asked to focuses")
    }

    @Test func secureEventInputFollowsFocus() {
        let (textView, _, _) = makeEditor()
        textView.beginSecureEventInput()
        #expect(textView.hasSecureEventInput)
        #expect(IsSecureEventInputEnabled())
        textView.beginSecureEventInput()
        textView.endSecureEventInput()
        #expect(!textView.hasSecureEventInput)
        textView.endSecureEventInput()
        #expect(!textView.hasSecureEventInput)
    }
}
