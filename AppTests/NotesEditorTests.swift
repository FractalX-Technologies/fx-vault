import AppKit
import Foundation
import SwiftUI
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// The notes editor's text view (1.0 N2, anton D3; boards Place-Edit, Place-SecretValue,
/// Place-Paste): headings stay, a secret's value is never typed or copied, pasted `KEY=value`
/// lines become tokens and the clipboard is cleared, undo lives in the edit.
@MainActor
@Suite("Notes editing: the editor")
struct NotesEditorTests {
    static let token = NotesEditAnalysis.tokenCharacter

    /// A repository scope with API_TOKEN (on GitHub, with a value) and LOG_LEVEL = info.
    static func editor() -> (NotesEditSession, NotesTextView) {
        let secret = NotesEditOriginModel(
            id: ConfigItemID(), name: "API_TOKEN", kind: .secret, isSynced: true, hasValue: true,
            variableValue: nil, mark: nil, note: nil, overrides: nil
        )
        let variable = NotesEditOriginModel(
            id: ConfigItemID(), name: "LOG_LEVEL", kind: .variable, isSynced: true, hasValue: true,
            variableValue: "info", mark: nil, note: nil, overrides: nil
        )
        let target = NotesEditTargetModel(kind: .repository, title: "production", parent: "api-service") { _ in }
        let session = NotesEditSession(target: target, origins: [secret, variable])
        let view = NotesTextView(session: session)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        return (session, view)
    }

    /// A pasteboard of the test's own: the user's clipboard is never touched.
    static func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("io.fractalx.fxvault.tests.\(UUID().uuidString)"))
    }

    static func range(of text: String, in view: NSTextView) -> NSRange {
        (view.string as NSString).range(of: text)
    }

    /// Types `text` at the insertion point, one character at a time as the keyboard does.
    static func type(_ text: String, in view: NSTextView) {
        for character in text {
            view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// Line `index`'s note (from 0), nil past the end.
    static func note(_ session: NotesEditSession, line index: Int) -> NotesEditNoteModel? {
        session.analysis.lines.dropFirst(index).first?.note
    }

    /// A new line under API_TOKEN, the insertion point on it.
    static func newSecretLine(in view: NSTextView) {
        view.setSelectedRange(NSRange(location: NSMaxRange(range(of: "API_TOKEN = \(token)", in: view)), length: 0))
        type("\n", in: view)
    }

    @Test func startsWithTheItemsUnderTheirHeadings() {
        let (session, view) = Self.editor()
        #expect(view.string == "# Secrets\nAPI_TOKEN = \(Self.token)\n\n# Variables\nLOG_LEVEL = info\n")
        #expect(session.changeCount == 0)
        #expect(session.errorCount == 0)
    }

    @Test func headingsStayWholeAndFirstOnTheirLine() {
        let (_, view) = Self.editor()
        let before = view.string

        view.setSelectedRange(NSRange(location: 3, length: 0))
        Self.type("x", in: view)
        view.setSelectedRange(Self.range(of: "# Secrets", in: view))
        view.deleteBackward(nil)
        #expect(view.string == before)

        // Backspace at the start of "# Variables" takes the blank line above, then stops: it
        // would join the heading to API_TOKEN's line.
        view.setSelectedRange(NSRange(location: Self.range(of: "# Variables", in: view).location, length: 0))
        view.deleteBackward(nil)
        #expect(view.string.contains("API_TOKEN = \(Self.token)\n# Variables\n"))
        view.deleteBackward(nil)
        #expect(view.string.contains("API_TOKEN = \(Self.token)\n# Variables\n"))

        // Return at a heading's end opens a line under it.
        view.setSelectedRange(NSRange(location: Self.range(of: "# Secrets", in: view).length, length: 0))
        Self.type("\n", in: view)
        #expect(view.string.hasPrefix("# Secrets\n\nAPI_TOKEN"))
    }

    /// Typing after a secret's `=` opens Set value…; `=` after a new secret's name brings its token.
    @Test func aSecretsValueIsNeverTypedIntoTheText() throws {
        let (session, view) = Self.editor()
        Self.newSecretLine(in: view)
        Self.type("NEW_KEY=", in: view)
        #expect(view.string.contains("NEW_KEY = \(Self.token)\n"))
        #expect(Self.note(session, line: 2) == .error(NotesEditCopy.setValue))

        Self.type("s3cr3t", in: view)
        #expect(!view.string.contains("s3cr3t"))
        #expect(session.valueRequest?.name == "NEW_KEY")
        #expect(session.valueRequest?.isNew == true)

        let request = try #require(session.valueRequest)
        session.commitValue("s3cr3t", for: request.id)
        #expect(!view.string.contains("s3cr3t"))
        #expect(Self.note(session, line: 2) == .info(NotesEditCopy.new(.secret)))
        #expect(session.analysis.plan.additions.map(\.name) == ["NEW_KEY"])
        #expect(session.canReview)
    }

    /// Copy writes `••••` for a token; a paste here brings the cut token back whole, a second
    /// paste a new "Set value…" one.
    @Test func copyMasksTokensAndAPasteHereKeepsThemWhole() throws {
        let (session, view) = Self.editor()
        let pasteboard = Self.pasteboard()
        defer { pasteboard.releaseGlobally() }

        view.setSelectedRange(Self.range(of: "API_TOKEN = \(Self.token)", in: view))
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "API_TOKEN = \(NotesCopy.maskToken)")

        view.deleteBackward(nil)
        #expect(session.analysis.plan.removals.map(\.name) == ["API_TOKEN"])
        #expect(view.readSelection(from: pasteboard, type: .string))
        #expect(session.changeCount == 0, "the cut line is back with its item")

        view.setSelectedRange(NSRange(location: NSMaxRange(Self.range(of: "API_TOKEN = \(Self.token)", in: view)), length: 0))
        Self.type("\n", in: view)
        #expect(view.readSelection(from: pasteboard, type: .string))
        let paragraphs = NotesEditText.paragraphs(of: view.attributedString())
        let tokens = paragraphs.flatMap(\.tokens)
        try #require(tokens.count == 2)
        #expect(Set(tokens).count == 2)
        #expect(session.tokens.origin(of: tokens[1]) == nil)
        #expect(Self.note(session, line: 2) == .error(NotesEditCopy.setValue))
        try session.tokens.setValue(SecretBytes(utf8: "copied"), for: tokens[1])
        session.update(paragraphs)
        #expect(Self.note(session, line: 2) == .error(NotesEditCopy.sameNameAsLine(2)))
        #expect(pasteboard.string(forType: .string) != nil, "a copy of the editor's own text stays")
    }

    @Test func pastedLinesBecomeTokensAndTheClipboardIsCleared() throws {
        let (session, view) = Self.editor()
        let pasteboard = Self.pasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("STRIPE_KEY=sk_test_1\nmapbox_token=pk.2\n", forType: .string)

        Self.newSecretLine(in: view)
        #expect(view.readSelection(from: pasteboard, type: .string))
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(session.toast == NotesEditCopy.pastedValues(2))
        #expect(!view.string.contains("sk_test_1"))
        #expect(!view.string.contains("pk.2"))
        #expect(view.string.contains("STRIPE_KEY = \(Self.token)\nMAPBOX_TOKEN = \(Self.token)\n"))

        let edits = session.makeEdits()
        defer { edits.wipe() }
        #expect(edits.additions.map(\.name) == ["STRIPE_KEY", "MAPBOX_TOKEN"])
        #expect(edits.additions.map { $0.value.utf8String() } == ["sk_test_1", "pk.2"])
    }

    /// Values pasted or typed in this edit read like a note in their tokens (the user has them on
    /// screen already); the text, a copy and an existing secret still hold none.
    @Test func newSecretValuesShowInTheirTokens() throws {
        let (session, view) = Self.editor()
        let pasteboard = Self.pasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("key1=secret1\nkey2=secret2\n", forType: .string)

        Self.newSecretLine(in: view)
        #expect(view.readSelection(from: pasteboard, type: .string))
        #expect(view.string.contains("KEY1 = \(Self.token)\nKEY2 = \(Self.token)\n"))
        #expect(!view.string.contains("secret1"))
        let tokens = NotesEditText.paragraphs(of: view.attributedString()).flatMap(\.tokens)
        #expect(tokens.map(session.display(of:)) == [.masked(oversizeBytes: nil), .visible("secret1"), .visible("secret2")])
        #expect(NotesTokenDrawing.label(for: .visible("secret1")) == "secret1")

        view.selectAll(nil)
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string)?.contains("secret") == false, "a copy writes the mask")
    }

    /// A long value shows its start and end in a chip of bounded width.
    @Test func aLongVisibleValueIsShortenedInTheMiddle() {
        let value = String(repeating: "a", count: 40) + String(repeating: "z", count: 40)
        let label = NotesTokenDrawing.label(for: .visible(value))
        #expect(label.count == NotesTokenDrawing.visibleMaxCharacters)
        #expect(label.hasPrefix("aaaa") && label.hasSuffix("zzzz") && label.contains("…"))
    }

    /// Key material that reads as `name=value` to the `.env` parser: Base64 with its padding
    /// and connection strings (short made-up keys).
    nonisolated static let keyMaterial = [
        "c2VjcmV0MTIzNDU2Nzg5MA==",
        "Endpoint=sb://example.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=ZXhhbXBsZQ==",
        "DefaultEndpointsProtocol=https;AccountName=example;AccountKey=ZXhhbXBsZQ==;EndpointSuffix=core.windows.net",
    ]

    /// Random-looking text made at run time, its first character among `alphabet`'s first
    /// `leading`, so the secret scanners find no key in this file.
    nonisolated static func fixture(_ count: Int, alphabet: String, leading: Int, seed: UInt64) -> String {
        let characters = Array(alphabet)
        var state = seed
        return String((0..<count).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return characters[Int(state >> 33) % (index == 0 ? leading : characters.count)]
        })
    }

    nonisolated static let base62 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

    nonisolated static let hex = "abcdef0123456789"

    /// Values GitHub takes as names too: a 32-byte key in Base64 with one `=`, unpadded Base64,
    /// 40 hex digits, GitHub and Stripe tokens, and lowercase-hex tokens the classifier has no
    /// prefix for (Shopify, DigitalOcean, Supabase).
    nonisolated static let valuesThatPassAsNames = [
        fixture(43, alphabet: base62, leading: 52, seed: 1) + "=",
        fixture(47, alphabet: base62, leading: 52, seed: 2),
        fixture(40, alphabet: hex, leading: 6, seed: 3),
        "ghp" + "_" + fixture(36, alphabet: base62, leading: 62, seed: 4),
        "sk" + "_live_" + fixture(24, alphabet: base62, leading: 62, seed: 5),
        "shp" + "at_" + fixture(32, alphabet: hex, leading: 16, seed: 9),
        "dop" + "_v1_" + fixture(64, alphabet: hex, leading: 16, seed: 10),
        "sbp" + "_" + fixture(40, alphabet: hex, leading: 16, seed: 11),
    ]

    /// Short keys under the entropy check's 20 characters: a word in both cases with a digit,
    /// and Base64 with its padding.
    nonisolated static let shortValues = ["r8Kq2mXz9TfA", "dGVzdEtleTE="]

    /// Names are plaintext on disk, in gh's arguments and on GitHub (SECURITY-MODEL §7): a value
    /// never becomes one, nor does a line without a value.
    @Test(arguments: keyMaterial + ["NEW_KEY=", "API_KEY=="] + valuesThatPassAsNames.map { "\($0)=x" })
    func pastedKeyMaterialIsNeverReadAsNames(_ text: String) {
        #expect(NotesPasteParser.entries(in: text, place: .repository) == nil)
    }

    @Test func pastedAssignmentsStillReadAsLines() throws {
        let entries = try #require(NotesPasteParser.entries(in: "A_KEY=one\nb_key=two\n", place: .repository))
        defer { entries.forEach { $0.value.wipe() } }
        #expect(entries.map(\.name) == ["A_KEY", "B_KEY"])
        for line in ["database_url=postgres://db.example.invalid/app", "aws_s3_bucket_name_2=example-bucket"] {
            let single = try #require(NotesPasteParser.entries(in: line, place: .repository))
            defer { single.forEach { $0.value.wipe() } }
            #expect(single.count == 1)
        }
    }

    /// Board Place-Paste: one line among the secrets that is not a name opens Set value… with it,
    /// on a new line whose name is still to type. The text never holds it.
    @Test(arguments: keyMaterial)
    func keyMaterialPastedAmongTheSecretsOpensSetValue(_ value: String) throws {
        let (session, view) = Self.editor()
        Self.newSecretLine(in: view)
        try Self.expectPasteOpensSetValue(value, in: session, view)
        #expect(view.string == "# Secrets\nAPI_TOKEN = \(Self.token)\n = \(Self.token)\n\n# Variables\nLOG_LEVEL = info\n")
    }

    /// A value that is a valid name too (a token, a Base64 or hex key) is still a value.
    @Test(arguments: valuesThatPassAsNames + shortValues)
    func aValueThatPassesAsANameOpensSetValue(_ value: String) throws {
        let name = value.hasSuffix("=") ? String(value.dropLast()) : value
        #expect(NotesEditPlaceKind.repository.nameProblem(name) == nil, "the fixture reads as a name")
        let (session, view) = Self.editor()
        Self.newSecretLine(in: view)
        try Self.expectPasteOpensSetValue(value, in: session, view)
    }

    /// In a Key Vault a dash counts as `_`: Slack and OpenAI keys pass as names there.
    @Test func aKeyVaultTakesDashedKeysAsValues() throws {
        let values = [
            "xox" + "b-" + Self.fixture(12, alphabet: "0123456789", leading: 9, seed: 6) + "-" + Self.fixture(24, alphabet: Self.base62, leading: 62, seed: 7),
            "sk" + "-proj-" + Self.fixture(48, alphabet: Self.base62, leading: 62, seed: 8),
        ]
        for value in values {
            #expect(NotesEditPlaceKind.keyVault.nameProblem(value) == nil, "the fixture reads as a name")
            let (session, view) = Self.keyVaultEditor()
            try Self.expectPasteOpensSetValue(value, in: session, view)
        }
    }

    /// An empty Key Vault's editor, the insertion point at the end.
    static func keyVaultEditor() -> (NotesEditSession, NotesTextView) {
        let target = NotesEditTargetModel(kind: .keyVault, title: "kv-example-prod", parent: nil) { _ in }
        let session = NotesEditSession(target: target, origins: [])
        let view = NotesTextView(session: session)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        return (session, view)
    }

    /// Names that look random to the entropy check alone still paste as names.
    @Test(arguments: ["STRIPE_SECRET_KEY", "AWS_S3_BUCKET_NAME_2", "GOOGLE_APPLICATION_CREDENTIALS_JSON_B64", "aws_s3_bucket_name_2"])
    func namesStillPasteAsNames(_ name: String) {
        let (session, view) = Self.editor()
        Self.newSecretLine(in: view)
        Self.expectPasteIsAName(name, in: session, view)
        #expect(view.string.contains("API_TOKEN = \(Self.token)\n\(name)\n"))
    }

    /// A Key Vault's names, dashes included, still paste as names.
    @Test(arguments: ["Db-Password1", "STRIPE_SECRET_KEY", "AWS_S3_BUCKET_NAME_2"])
    func keyVaultNamesStillPasteAsNames(_ name: String) {
        let (session, view) = Self.keyVaultEditor()
        Self.expectPasteIsAName(name, in: session, view)
    }

    /// Pastes `name` at the insertion point: it goes in as text, and the clipboard keeps it.
    static func expectPasteIsAName(_ name: String, in session: NotesEditSession, _ view: NotesTextView) {
        let pasteboard = Self.pasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(name, forType: .string)

        #expect(view.readSelection(from: pasteboard, type: .string))
        #expect(view.string.contains("\(name)\n") || view.string.hasSuffix(name))
        #expect(session.valueRequest == nil)
        #expect(pasteboard.string(forType: .string) == name)
    }

    /// Pastes `value` at the insertion point: it opens Set value… with it, adds no name, keeps
    /// it out of the text and leaves the clipboard.
    static func expectPasteOpensSetValue(_ value: String, in session: NotesEditSession, _ view: NotesTextView) throws {
        let pasteboard = Self.pasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)

        #expect(view.readSelection(from: pasteboard, type: .string))
        #expect(!view.string.contains(value) && !view.string.contains(String(value.prefix(12))))
        #expect(session.analysis.plan.additions.isEmpty)
        let request = try #require(session.valueRequest)
        #expect(session.currentText(of: request) == value)
        #expect(pasteboard.string(forType: .string) == nil, "the value left the clipboard")
    }

    /// After a secret's `=` the whole paste is that line's value, even `KEY=value` lines.
    @Test func aPasteAfterASecretsEqualsIsItsValue() {
        let (session, view) = Self.editor()
        let pasteboard = Self.pasteboard()
        defer { pasteboard.releaseGlobally() }
        let value = "A_KEY=one\nB_KEY=two"
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)

        view.setSelectedRange(NSRange(location: NSMaxRange(Self.range(of: "API_TOKEN = \(Self.token)", in: view)), length: 0))
        #expect(view.readSelection(from: pasteboard, type: .string))
        #expect(view.string == "# Secrets\nAPI_TOKEN = \(Self.token)\n\n# Variables\nLOG_LEVEL = info\n")
        #expect(session.analysis.plan.additions.isEmpty)
        #expect(session.toast == NotesEditCopy.pastedValues(1))
        #expect(pasteboard.string(forType: .string) == nil)
        let edits = session.makeEdits()
        defer { edits.wipe() }
        #expect(edits.changes.map { $0.value?.utf8String() } == [value])
    }

    /// Among the secrets, text of several lines that are not `KEY=value` is refused: it can only
    /// be a value. A name pastes as text.
    @Test func otherTextAmongTheSecretsIsANameOrNothing() {
        let (session, view) = Self.editor()
        let pasteboard = Self.pasteboard()
        defer { pasteboard.releaseGlobally() }
        Self.newSecretLine(in: view)
        let before = view.string
        pasteboard.clearContents()
        pasteboard.setString("first part\nsecond part", forType: .string)
        #expect(view.readSelection(from: pasteboard, type: .string))
        #expect(view.string == before)
        #expect(session.valueRequest == nil)
        #expect(pasteboard.string(forType: .string) != nil, "nothing was read")

        pasteboard.clearContents()
        pasteboard.setString("STRIPE_KEY", forType: .string)
        #expect(view.readSelection(from: pasteboard, type: .string))
        #expect(view.string.contains("API_TOKEN = \(Self.token)\nSTRIPE_KEY\n"))
    }

    /// The key typed after a secret's `=` is the value's first character, not lost.
    @Test func theKeyThatOpensSetValueStartsItsField() throws {
        let (session, view) = Self.editor()
        Self.newSecretLine(in: view)
        Self.type("NEW_KEY=a", in: view)
        let request = try #require(session.valueRequest)
        #expect(session.currentText(of: request) == "a")
        #expect(view.string.contains("NEW_KEY = \(Self.token)\n"))
    }

    /// A value set in place (Done, a paste after `=`, a pasted name the section has) is an undo
    /// step: Undo puts the line's earlier value back.
    @Test func aValueSetInPlaceUndoes() throws {
        let (session, view) = Self.editor()
        let original = view.string
        let token = try #require(NotesEditText.paragraphs(of: view.attributedString()).flatMap(\.tokens).first)
        session.commitValue("rotated", for: token)
        #expect(session.analysis.plan.changes.count == 1)
        #expect(session.undoManager.canUndo)

        session.undoManager.undo()
        #expect(session.changeCount == 0)
        #expect(view.string == original)
        let edits = session.makeEdits()
        defer { edits.wipe() }
        #expect(edits.changes.isEmpty)
    }

    /// The toast says the clipboard was cleared only when nothing was copied since the paste.
    @Test func theClipboardIsClearedOnlyWhenUnchanged() {
        let pasteboard = Self.pasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("pasted", forType: .string)
        let pasted = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("copied since", forType: .string)
        #expect(!NotesClipboard.clear(pasteboard, ifStillAt: pasted))
        #expect(pasteboard.string(forType: .string) == "copied since")
        #expect(NotesClipboard.clear(pasteboard, ifStillAt: pasteboard.changeCount))
        #expect(pasteboard.string(forType: .string) == nil)

        let (session, _) = Self.editor()
        session.didPasteValues(2, clearedClipboard: false)
        #expect(session.toast == NotesEditCopy.pastedValuesKept(2))
        session.didPasteValues(2, clearedClipboard: true)
        #expect(session.toast == NotesEditCopy.pastedValues(2))
    }

    /// Set value… shows what is typed: its window stays out of screen capture (§5.11).
    @Test func setValueStaysOutOfScreenCapture() async throws {
        let (session, view) = Self.editor()
        Self.newSecretLine(in: view)
        Self.type("NEW_KEY=a", in: view)
        let request = try #require(session.valueRequest)
        let popover = NotesValuePopover(request: request, initialText: "a", hasVariables: true, session: session) {}
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        #expect(window.sharingType != .none)
        window.contentView = NSHostingView(rootView: popover)
        #expect(await TestFixtures.eventually { window.sharingType == .none })
    }

    /// A pasted name the section has sets that line's value; a variable's goes in as its text.
    @Test func aPastedNameTheSectionHasReplacesItsValue() {
        let (session, view) = Self.editor()
        let pasteboard = Self.pasteboard()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("API_TOKEN=rotated", forType: .string)
        Self.newSecretLine(in: view)
        #expect(view.readSelection(from: pasteboard, type: .string))
        #expect(Self.note(session, line: 1) == .info(NotesEditCopy.replacesValue))
        #expect(session.analysis.plan.changes.count == 1)

        pasteboard.clearContents()
        pasteboard.setString("LOG_LEVEL=debug", forType: .string)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        #expect(view.readSelection(from: pasteboard, type: .string))
        #expect(view.string.contains("LOG_LEVEL = debug\n"))
        #expect(session.analysis.plan.changes.count == 2)
    }

    @Test func otherTextPastesAsTextAndStaysOnTheClipboard() {
        let (_, view) = Self.editor()
        let pasteboard = Self.pasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("# rotate monthly", forType: .string)

        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        #expect(view.readSelection(from: pasteboard, type: .string))
        #expect(view.string.hasSuffix("LOG_LEVEL = info\n# rotate monthly"))
        #expect(pasteboard.string(forType: .string) == "# rotate monthly")
    }

    /// A file secret's token reads its file as in the notes (1.0 F1) until a new value replaces it.
    @Test func aFileSecretsTokenNamesItsFileUntilItsValueChanges() throws {
        let file = FileSecretModel(fileName: "AuthKey_ABC123.p8", lineCount: 6, encoding: .text)
        let origin = NotesEditOriginModel(
            id: ConfigItemID(), name: "APNS_KEY", kind: .secret, isSynced: true, hasValue: true,
            variableValue: nil, mark: nil, note: nil, overrides: nil, file: file
        )
        let target = NotesEditTargetModel(kind: .repository, title: "production", parent: "api-service") { _ in }
        let session = NotesEditSession(target: target, origins: [origin])
        let view = NotesTextView(session: session)
        let token = try #require(NotesEditText.paragraphs(of: view.attributedString()).flatMap(\.tokens).first)
        #expect(session.display(of: token) == .file(file))
        #expect(NotesTokenDrawing.label(for: .file(file)) == FileSecretCopy.notesLabel(file))

        try session.tokens.setValue(SecretBytes(utf8: "typed"), for: token)
        #expect(session.display(of: token) == .visible("typed"))
        let copy = try #require(session.tokens.duplicate(token))
        #expect(session.display(of: copy) == .setValue, "a copy of the line is a new secret")
    }

    /// A click on line 2 of the read notes starts the edit with the keyboard there, at its end.
    @Test func theEditorOpensWithTheCaretAtTheClickedLinesEnd() {
        let (session, view) = Self.editor()
        session.caretLine = 2
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        #expect(window.firstResponder === view)
        #expect(view.selectedRange() == NSRange(location: NSMaxRange(Self.range(of: "API_TOKEN = \(Self.token)", in: view)), length: 0))
    }

    /// Kind › Variable in Set value… moves a new secret's line under `# Variables`, its value as text.
    @Test func aNewSecretLineCanBecomeAVariable() throws {
        let (session, view) = Self.editor()
        Self.newSecretLine(in: view)
        Self.type("FLAG=x", in: view)
        let request = try #require(session.valueRequest)
        session.moveToVariables(request.id, text: "on")
        #expect(session.valueRequest == nil)
        #expect(!view.string.contains("FLAG = \(Self.token)"))
        #expect(view.string.contains("LOG_LEVEL = info\nFLAG = on"))
        #expect(session.analysis.plan.additions.map(\.kind) == [.variable])
    }

    /// "removed · Undo" puts the item's line back with its value: nothing left to save.
    @Test func undoOfARemovedItemBringsItBack() throws {
        let (session, view) = Self.editor()
        let text = view.string as NSString
        view.setSelectedRange(text.lineRange(for: text.range(of: "API_TOKEN")))
        view.deleteBackward(nil)
        let removed = try #require(session.analysis.plan.removals.first)
        #expect(removed.name == "API_TOKEN")

        session.restore(removed)
        #expect(session.analysis.plan.removals.isEmpty)
        #expect(session.changeCount == 0)
        #expect(view.string.contains("API_TOKEN = \(Self.token)"))
    }

    /// A save the vault refuses keeps the edit open and says why.
    @Test func aRefusedSaveKeepsTheEdit() {
        let target = NotesEditTargetModel(kind: .repository, title: "production", parent: nil) { _ throws(ConfigRepositoryError) in
            throw .repositoryNotFound
        }
        let session = NotesEditSession(target: target, origins: [])
        let view = NotesTextView(session: session)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        Self.type("\nDEBUG=1", in: view)
        session.requestReview()
        #expect(session.review != nil)

        session.save()
        #expect(session.review == nil)
        #expect(session.alert == ConfigRepositoryError.repositoryNotFound.presentation)
        #expect(!session.isFinished)
        #expect(view.string.contains("DEBUG=1") || view.string.contains("DEBUG = 1"))
    }

    @Test func undoLivesOnlyWhileEditing() {
        let (session, view) = Self.editor()
        #expect(view.undoManager === session.undoManager)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        Self.type("DEBUG=1", in: view)
        view.breakUndoCoalescing()
        #expect(session.undoManager.canUndo)

        session.cancel()
        #expect(!session.undoManager.canUndo)
        #expect(session.isFinished)
    }

    /// Nothing may change typed or pasted bytes, keep a copy or drag a token out as text.
    @Test func textServicesAreOff() {
        let (_, view) = Self.editor()
        #expect(!view.isAutomaticQuoteSubstitutionEnabled)
        #expect(!view.isAutomaticDashSubstitutionEnabled)
        #expect(!view.isAutomaticTextReplacementEnabled)
        #expect(!view.isAutomaticSpellingCorrectionEnabled)
        #expect(!view.isContinuousSpellCheckingEnabled)
        #expect(!view.isGrammarCheckingEnabled)
        #expect(!view.isAutomaticTextCompletionEnabled)
        #expect(view.writingToolsBehavior == .none)
        #expect(view.inlinePredictionType == .no)
        #expect(view.acceptableDragTypes.isEmpty)
        #expect(view.textLayoutManager != nil, "TextKit 2")
    }

    @Test func generatedValuesAreRandomBase64URL() {
        let first = NotesValueGenerator.value()
        let second = NotesValueGenerator.value()
        #expect(first.count == 43)
        #expect(first != second)
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    }
}
