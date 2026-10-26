import AppKit
import SwiftUI
import VaultCore

/// The notes editor (1.0 N2, anton D3): an `NSTextView` on TextKit 2 that never holds a secret's
/// value. Values are tokens (``NotesTokenAttachment``) set in Set value…; typing one into a secret's
/// line opens it instead, a copy writes `••••`, a pasted `KEY=value` line becomes a token and the
/// clipboard is cleared. Undo lives in the edit only; substitutions and Writing Tools are off.
final class NotesTextView: NSTextView {
    let session: NotesEditSession
    /// TextKit 2's storage: the layout manager holds it weakly.
    private let contentStorage: NSTextContentStorage
    /// The layout manager's delegate, held here: it holds it weakly.
    private let layoutDelegate = NotesLayoutDelegate()
    /// Set while the editor changes its own text (paste, tokens, Undo of a removal).
    private var isProgrammaticEdit = false
    private var needsLayoutPublish = false
    private var popover: NSPopover?
    private var didFocus = false

    init(session: NotesEditSession) {
        self.session = session
        let contentStorage = NSTextContentStorage()
        let textLayout = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(textLayout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        textLayout.textContainer = container
        self.contentStorage = contentStorage
        super.init(frame: .zero, textContainer: container)
        textLayout.delegate = layoutDelegate
        configure()
        session.editor = self
        if let text = session.text {
            // The previous editor's undo steps point at its own text.
            session.undoManager.removeAllActions()
            textStorage?.setAttributedString(text)
        } else {
            textStorage?.setAttributedString(NotesEditText.document(session.initialLines, tokens: session.tokens, renderer: session))
        }
        session.update(NotesEditText.paragraphs(of: attributedString()))
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        delegate = self
        isRichText = true
        allowsUndo = true
        turnOffTextServices()
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = NSSize(width: 0, height: Theme.Spacing.smallMinus)
        insertionPointColor = Theme.Colors.Editor.ink
        typingAttributes = NotesEditText.baseAttributes
        setAccessibilityLabel(NotesEditCopy.accessibilityLabel)
        setAccessibilityIdentifier(AccessibilityID.Place.notesEditor)
    }

    // MARK: - Nothing kept outside the edit

    /// No restorable state: the window must not write the edit to disk (anton D3).
    override func encodeRestorableState(with coder: NSCoder) {}

    /// Esc and F5 complete words from the dictionary: not in values.
    override func complete(_ sender: Any?) {}

    /// No drag in or out: a dragged token would arrive as `••••` text.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        []
    }

    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        false
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.string]
    }

    /// Cut, Copy, Paste and Select All: the spelling, substitution, font and speech menus would
    /// only offer what the editor turns off.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: NotesEditCopy.cut, action: #selector(cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: NotesEditCopy.copy, action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: NotesEditCopy.paste, action: #selector(paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: NotesEditCopy.selectAll, action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            popover?.close()
            return
        }
        guard !didFocus else { return }
        didFocus = true
        window.makeFirstResponder(self)
        let paragraphs = NotesEditText.paragraphRanges(of: text)
        let line = session.caretLine.flatMap { paragraphs.indices.contains($0 - 1) ? paragraphs[$0 - 1] : nil }
        setSelectedRange(NSRange(location: line.map(NSMaxRange) ?? text.length, length: 0))
    }

    // MARK: - Layout

    /// The line notes keep the trailing part of the width (``Theme/Layout/notesNoteColumnWidth``).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let notes = min(Theme.Layout.notesNoteColumnWidth, newSize.width * Theme.Layout.notesNoteColumnShare)
        let width = max(0, newSize.width - notes)
        if textContainer?.size.width != width {
            textContainer?.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            setNeedsLayoutPublish()
        }
    }

    private func setNeedsLayoutPublish() {
        guard !needsLayoutPublish else { return }
        needsLayoutPublish = true
        // After the current AppKit or SwiftUI pass: the frames feed SwiftUI state.
        Task { @MainActor [weak self] in
            self?.publishLayout()
        }
    }

    /// Lays out the whole text and hands the lines' frames to the edit.
    func publishLayout() {
        needsLayoutPublish = false
        guard let layoutManager = textLayoutManager else { return }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let origin = textContainerOrigin
        let width = textContainer?.size.width ?? bounds.width
        var lines: [CGRect] = []
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location, options: [.ensuresExtraLineFragment]) { fragment in
            let frame = fragment.layoutFragmentFrame
            var bottom = frame.minY
            var extraLine: CGRect?
            for (index, line) in fragment.textLineFragments.enumerated() {
                let bounds = line.typographicBounds.offsetBy(dx: 0, dy: frame.minY)
                // The empty line after a final line break is a paragraph of its own.
                if index > 0, line.characterRange.length == 0 {
                    extraLine = CGRect(x: origin.x, y: origin.y + bounds.minY, width: width, height: bounds.height)
                } else {
                    bottom = max(bottom, bounds.maxY)
                }
            }
            lines.append(CGRect(x: origin.x, y: origin.y + frame.minY, width: width, height: max(bottom - frame.minY, NotesEditText.lineHeight)))
            if let extraLine {
                lines.append(extraLine)
            }
            return true
        }
        let paragraphs = NotesEditText.paragraphRanges(of: text)
        lines = Self.complete(lines, count: paragraphs.count, origin: origin, width: width)
        var layout = NotesEditLayoutModel(height: (lines.last?.maxY ?? 0) + textContainerInset.height, width: bounds.width, lines: lines)
        let lineHeight = NotesEditText.lineHeight
        for (index, line) in session.analysis.lines.enumerated() where index < paragraphs.count {
            let paragraph = paragraphs[index]
            if let range = line.nameErrorRange, let rect = segmentRect(NSRange(location: paragraph.location + range.location, length: range.length)) {
                // On its whole line: a segment's height is its glyphs', not the fixed line's.
                let top = origin.y + ((rect.midY - origin.y) / lineHeight).rounded(.down) * lineHeight
                layout.squiggles.append(CGRect(x: rect.minX, y: top, width: rect.width, height: lineHeight))
            }
            if case .heading = line.role, let rect = segmentRect(paragraph) {
                layout.headingEnds[index] = rect.maxX
            }
        }
        let caret = selectedRange().location
        layout.caretLine = paragraphs.firstIndex { caret >= $0.location && caret <= NSMaxRange($0) }
        if session.layout != layout {
            session.layout = layout
        }
    }

    /// One frame per paragraph: lines TextKit has not laid out yet follow the last one.
    private static func complete(_ lines: [CGRect], count: Int, origin: CGPoint, width: CGFloat) -> [CGRect] {
        var lines = Array(lines.prefix(count))
        while lines.count < count {
            let top = lines.last?.maxY ?? origin.y
            lines.append(CGRect(x: origin.x, y: top, width: width, height: NotesEditText.lineHeight))
        }
        return lines
    }

    /// Where `range`'s characters are drawn, in the view.
    func segmentRect(_ range: NSRange) -> CGRect? {
        guard let layoutManager = textLayoutManager, let textRange = textRange(range) else { return nil }
        var result: CGRect?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, rect, _, _ in
            result = result.map { $0.union(rect) } ?? rect
            return true
        }
        let origin = textContainerOrigin
        return result?.offsetBy(dx: origin.x, dy: origin.y)
    }

    private func textRange(_ range: NSRange) -> NSTextRange? {
        let document = contentStorage.documentRange.location
        guard let start = contentStorage.location(document, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    // MARK: - Reading the text

    private var text: NSString {
        string as NSString
    }

    /// The `# Secrets` and `# Variables` lines, without their line break.
    private var headings: [(range: NSRange, kind: ConfigKind)] {
        var headings: [(NSRange, ConfigKind)] = []
        let storage = attributedString()
        storage.enumerateAttribute(.notesHeading, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let kind = (value as? String).flatMap(ConfigKind.init(rawValue:)) {
                headings.append((range, kind))
            }
        }
        return headings
    }

    /// The section of the line holding `location`.
    func section(at location: Int) -> ConfigKind {
        headings.last { $0.range.location <= location }?.kind ?? session.target.kind.kinds.first ?? .secret
    }

    /// The line holding `location`, without its line break.
    func paragraphRange(at location: Int) -> NSRange {
        NotesEditText.paragraphRanges(of: text).first { NSLocationInRange(location, NSRange(location: $0.location, length: $0.length + 1)) }
            ?? NSRange(location: text.length, length: 0)
    }

    /// The tokens in `range`, in order.
    private func tokens(in range: NSRange) -> [(id: NotesTokenID, range: NSRange)] {
        NotesEditText.tokens(in: attributedString(), range: range)
    }

    /// The name before a line's `=`.
    private func name(onLine line: NSRange) -> String {
        let lineText = text.substring(with: line)
        let name = lineText.components(separatedBy: "=").first ?? lineText
        return name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Editing the text itself

    /// An undoable change the guard does not check: the editor's own (paste, tokens, Undo).
    private func replace(_ range: NSRange, with replacement: NSAttributedString) {
        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
    }

    private func plain(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: NotesEditText.baseAttributes)
    }

    /// `NAME = value` for a new line of `kind`: a secret's value, or one with line breaks, as a token.
    private func newLine(name: String, value: SecretBytes, kind: ConfigKind) -> NSAttributedString {
        let line = NSMutableAttributedString(attributedString: plain("\(name) = "))
        if kind == .variable, let text = value.utf8String(), !text.contains(where: \.isNewline) {
            line.append(plain(text))
        } else {
            let token = session.tokens.make(kind: kind)
            do {
                try session.tokens.setValue(value, for: token)
            } catch {
                // An empty value leaves the token to set: the line says "Set a value".
            }
            line.append(NotesEditText.token(token, renderer: session))
        }
        return line
    }

    /// Where a new line of `kind` goes: after the section's last line that is not blank.
    private func endOfSection(_ kind: ConfigKind) -> Int {
        let sections = headings
        guard let index = sections.firstIndex(where: { $0.kind == kind }) else { return text.length }
        let start = NSMaxRange(sections[index].range)
        let stop = index + 1 < sections.count ? sections[index + 1].range.location : text.length
        var end = start
        for line in NotesEditText.paragraphRanges(of: text) where line.location >= start && NSMaxRange(line) <= stop {
            if !text.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty {
                end = NSMaxRange(line)
            }
        }
        return end
    }
}

// MARK: - Guarding typed edits

extension NotesTextView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard !isProgrammaticEdit else { return true }
        // An attributes-only change (a font or a style): the editor keeps its own.
        guard let replacementStrings else { return false }
        let ranges = affectedRanges.map(\.rangeValue)
        let headingRanges = headings.map(\.range)
        for (range, replacement) in zip(ranges, replacementStrings)
        where !NotesEditGuard.allows(range, replacement: replacement, in: text, headings: headingRanges) {
            NSSound.beep()
            return false
        }
        guard ranges.count == 1, let range = ranges.first, let replacement = replacementStrings.first else { return true }
        return allowsOnSecretLine(range, replacement)
    }

    /// A secret's value is never typed into the text: typing after its `=` opens Set value…, and
    /// typing `=` after a secret's name brings its token.
    private func allowsOnSecretLine(_ range: NSRange, _ replacement: String) -> Bool {
        guard !replacement.isEmpty, !replacement.contains(where: \.isNewline), section(at: range.location) == .secret else { return true }
        let line = paragraphRange(at: range.location)
        let lineText = text.substring(with: line) as NSString
        let equals = lineText.range(of: "=")
        let offset = range.location - line.location
        guard equals.location != NSNotFound else {
            let isAtEnd = lineText.substring(from: min(offset + range.length, lineText.length)).trimmingCharacters(in: .whitespaces).isEmpty
            guard replacement == "=", isAtEnd, tokens(in: line).isEmpty else { return true }
            let spacer = offset > 0 && lineText.character(at: offset - 1) == UInt16(UInt8(ascii: " ")) ? "" : " "
            let token = session.tokens.make(kind: .secret)
            let insertion = NSMutableAttributedString(attributedString: plain("\(spacer)= "))
            insertion.append(NotesEditText.token(token, renderer: session))
            replace(range, with: insertion)
            return false
        }
        guard offset > equals.location, !replacement.allSatisfy({ $0 == " " || $0 == "\t" }) else { return true }
        requestValue(onLine: line)
        return false
    }

    func textDidChange(_ notification: Notification) {
        // A copy: `attributedString()` is the live storage.
        let text = NSAttributedString(attributedString: attributedString())
        session.text = text
        session.update(NotesEditText.paragraphs(of: text))
        setNeedsLayoutPublish()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        setNeedsLayoutPublish()
    }

    /// Typed text is plain: never a heading's style or an item's identity.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any], toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        NotesEditText.baseAttributes
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        session.undoManager
    }
}

// MARK: - Copy and paste

extension NotesTextView {
    /// Copy and Cut write plain text, a token as `••••`; the editor remembers the fragment so a
    /// paste here brings the tokens back whole.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let ranges = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else { return false }
        let fragment = NSMutableAttributedString()
        for (index, range) in ranges.enumerated() {
            if index > 0 {
                fragment.append(plain(NotesEditText.newline))
            }
            fragment.append(attributedString().attributedSubstring(from: range))
        }
        pboard.clearContents()
        guard pboard.setString(NotesEditText.plainText(of: fragment), forType: .string) else { return false }
        session.copiedFragment = (pboard.changeCount, fragment)
        return true
    }

    /// ⌘V: the editor's own copy whole, else `KEY=value` lines or one secret's value as tokens
    /// (then the clipboard is cleared), else plain text.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let string = pboard.string(forType: .string) else { return false }
        let changeCount = pboard.changeCount
        if let copied = session.copiedFragment, copied.changeCount == changeCount {
            return insertFragment(copied.text)
        }
        let count = pasteValues(string)
        guard count > 0 else {
            return insertFragment(plain(string.replacingOccurrences(of: NotesEditAnalysis.tokenCharacter, with: "")))
        }
        // Only what was pasted: anything copied since stays.
        if pboard.changeCount == changeCount {
            pboard.clearContents()
        }
        session.didPasteValues(count)
        return true
    }

    /// Inserts text at the selection when the guard allows it. A copied token whose own line is
    /// still here comes back as a new "Set value…" one: a copy of a line is a new line.
    private func insertFragment(_ fragment: NSAttributedString) -> Bool {
        let copy = NSMutableAttributedString(attributedString: fragment)
        let whole = NSRange(location: 0, length: copy.length)
        let document = NSRange(location: 0, length: text.length)
        let present = Set(tokens(in: document).map(\.id))
        for token in NotesEditText.tokens(in: copy, range: whole).reversed() where present.contains(token.id) {
            if let fresh = session.tokens.duplicate(token.id) {
                copy.replaceCharacters(in: token.range, with: NotesEditText.token(fresh, renderer: session))
            }
        }
        let items = Set(NotesEditText.paragraphs(of: attributedString()).compactMap(\.itemID).map(\.uuidString))
        copy.enumerateAttributes(in: NSRange(location: 0, length: copy.length)) { attributes, range, _ in
            if attributes[.notesHeading] != nil {
                copy.setAttributes(NotesEditText.baseAttributes, range: range)
            } else if let item = attributes[.notesItem] as? String, items.contains(item) {
                copy.removeAttribute(.notesItem, range: range)
            }
        }
        let range = selectedRange()
        guard NotesEditGuard.allows(range, replacement: copy.string, in: text, headings: headings.map(\.range)) else {
            NSSound.beep()
            return true
        }
        replace(range, with: copy)
        return true
    }

    /// Values a paste sets: `KEY=value` lines (board Place-Paste), or one value pasted after a
    /// secret's `=`. Returns how many; 0 leaves the paste to plain text.
    private func pasteValues(_ string: String) -> Int {
        let location = selectedRange().location
        let kind = section(at: location)
        if let entries = NotesPasteParser.entries(in: string, place: session.target.kind) {
            defer {
                for entry in entries {
                    entry.value.wipe()
                }
            }
            undoManager?.beginUndoGrouping()
            defer { undoManager?.endUndoGrouping() }
            var lines: [NSAttributedString] = []
            for entry in entries where !replaceValue(named: entry.name, kind: kind, with: entry.value) {
                lines.append(newLine(name: entry.name, value: entry.value, kind: kind))
            }
            insertLines(lines, near: location)
            return entries.count
        }
        let line = paragraphRange(at: location)
        let equals = (text.substring(with: line) as NSString).range(of: "=")
        guard kind == .secret, equals.location != NSNotFound, location - line.location > equals.location,
              let token = tokenOnLine(line) else { return 0 }
        let value = SecretBytes(utf8: string)
        defer { value.wipe() }
        do {
            try session.tokens.setValue(value, for: token)
        } catch {
            return 0
        }
        return 1
    }

    /// A pasted name the section already has replaces that line's value ("replaces value").
    private func replaceValue(named name: String, kind: ConfigKind, with value: SecretBytes) -> Bool {
        let place = session.target.kind
        let headingStarts = Set(headings.map(\.range.location))
        for line in NotesEditText.paragraphRanges(of: text) where !headingStarts.contains(line.location) && section(at: line.location) == kind {
            let equals = (text.substring(with: line) as NSString).range(of: "=")
            guard equals.location != NSNotFound, place.normalizedName(self.name(onLine: line)) == name else { continue }
            if let token = tokens(in: line).last?.id {
                do {
                    try session.tokens.setValue(value, for: token)
                } catch {
                    // `KEY=` with nothing after it: the line keeps its value.
                }
                return true
            }
            let valueStart = line.location + equals.location + 1
            replace(NSRange(location: valueStart, length: NSMaxRange(line) - valueStart), with: newValue(value, kind: kind))
            return true
        }
        return false
    }

    /// ` value` after a line's `=`: a variable's text, or a token.
    private func newValue(_ value: SecretBytes, kind: ConfigKind) -> NSAttributedString {
        let line = newLine(name: "", value: value, kind: kind)
        // `newLine` starts with " = ": keep the space, drop the `=` before it.
        return line.attributedSubstring(from: NSRange(location: 2, length: line.length - 2))
    }

    /// New lines under the insertion point's line, or in its place when it is blank.
    private func insertLines(_ lines: [NSAttributedString], near location: Int) {
        guard !lines.isEmpty else { return }
        let joined = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                joined.append(plain(NotesEditText.newline))
            }
            joined.append(line)
        }
        let line = paragraphRange(at: location)
        let isHeading = headings.contains { $0.range.location == line.location }
        if !isHeading, text.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty {
            replace(line, with: joined)
            return
        }
        let insertion = NSMutableAttributedString(attributedString: plain(NotesEditText.newline))
        insertion.append(joined)
        replace(NSRange(location: NSMaxRange(line), length: 0), with: insertion)
    }
}

// MARK: - Tokens and Set value…

extension NotesTextView: NSPopoverDelegate {
    /// A click on a token opens Set value….
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let document = NSRange(location: 0, length: text.length)
        if let hit = tokens(in: document).first(where: { segmentRect($0.range)?.contains(point) == true }) {
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: NSMaxRange(hit.range), length: 0))
            presentValueEditor(for: hit.id, line: paragraphRange(at: hit.range.location))
            return
        }
        super.mouseDown(with: event)
    }

    /// The token on a secret's line, made at the end of the line when it has none.
    private func tokenOnLine(_ line: NSRange) -> NotesTokenID? {
        if let token = tokens(in: line).last {
            return token.id
        }
        let token = session.tokens.make(kind: section(at: line.location))
        let insertion = NSMutableAttributedString()
        if !text.substring(with: line).hasSuffix(" ") {
            insertion.append(plain(" "))
        }
        insertion.append(NotesEditText.token(token, renderer: session))
        replace(NSRange(location: NSMaxRange(line), length: 0), with: insertion)
        return token
    }

    /// Opens Set value… for the token on `line`.
    func requestValue(onLine line: NSRange) {
        guard let token = tokenOnLine(line) else { return }
        presentValueEditor(for: token, line: paragraphRange(at: line.location))
    }

    private func presentValueEditor(for token: NotesTokenID, line: NSRange) {
        session.requestValue(for: token, name: name(onLine: line))
        guard let request = session.valueRequest, window != nil,
              let anchor = tokens(in: line).first(where: { $0.id == token }).flatMap({ segmentRect($0.range) }) else { return }
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        let content = NotesValuePopover(
            request: request,
            initialText: session.currentText(of: request),
            hasVariables: session.target.kind.kinds.contains(.variable),
            session: session
        ) { [weak popover] in
            popover?.performClose(nil)
        }
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        self.popover = popover
    }

    func popoverDidClose(_ notification: Notification) {
        session.valueRequest = nil
        popover = nil
        window?.makeFirstResponder(self)
    }
}

// MARK: - What the edit asks of the editor

extension NotesTextView: NotesEditorCommands {
    func tokensDidChange() {
        if let layoutManager = textLayoutManager {
            layoutManager.invalidateLayout(for: layoutManager.documentRange)
            layoutManager.textViewportLayoutController.layoutViewport()
        }
        needsDisplay = true
        setNeedsLayoutPublish()
    }

    func moveLineToVariables(token: NotesTokenID, value: String) {
        guard let found = tokens(in: NSRange(location: 0, length: text.length)).first(where: { $0.id == token }) else { return }
        let line = paragraphRange(at: found.range.location)
        let name = name(onLine: line)
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        replace(NSRange(location: line.location, length: min(line.length + 1, text.length - line.location)), with: plain(""))
        let bytes = SecretBytes(utf8: value)
        defer { bytes.wipe() }
        let moved = value.isEmpty ? plain("\(name) = ") : newLine(name: name, value: bytes, kind: .variable)
        let insertion = NSMutableAttributedString(attributedString: plain(NotesEditText.newline))
        insertion.append(moved)
        replace(NSRange(location: endOfSection(.variable), length: 0), with: insertion)
    }

    func restore(_ line: NotesEditInitialLineModel, kind: ConfigKind) {
        let insertion = NSMutableAttributedString(attributedString: plain(NotesEditText.newline))
        insertion.append(NotesEditText.line(line, tokens: session.tokens, renderer: session))
        replace(NSRange(location: endOfSection(kind), length: 0), with: insertion)
    }
}
