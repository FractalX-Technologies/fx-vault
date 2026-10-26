import AppKit
import VaultCore

extension NSAttributedString.Key {
    /// A section's protected `# Secrets` or `# Variables` line (its `ConfigKind` raw value).
    static let notesHeading = NSAttributedString.Key("io.fractalx.fxvault.notes.heading")
    /// The existing variable these characters were loaded for (its id's text): the line's identity.
    static let notesItem = NSAttributedString.Key("io.fractalx.fxvault.notes.item")
}

/// The notes editor's text (1.0 N2): fixed 24 pt lines in SF Mono, a token as one attachment
/// character, and the paragraphs the analysis reads back.
enum NotesEditText {
    static let lineHeight = Theme.Layout.notesLineHeight
    static let newline = "\n"

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        // Values have no word boundaries worth keeping: wrap anywhere.
        style.lineBreakMode = .byCharWrapping
        return style
    }

    /// What every typed character gets: never a heading's or an item's identity.
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: Theme.Typography.nsNotes,
            .foregroundColor: Theme.Colors.Editor.ink,
            .paragraphStyle: paragraphStyle,
        ]
    }

    /// How far ``NotesLayoutFragment`` lifts a line's glyphs into the middle of the fixed line:
    /// TextKit 2 puts the extra height above them (a `.baselineOffset` would shorten the line).
    nonisolated static func glyphLift(for font: NSFont, lineHeight: CGFloat) -> CGFloat {
        max(0, (lineHeight - (font.ascender - font.descender)) / 2)
    }

    static func sectionTitle(_ kind: ConfigKind) -> String {
        NotesCopy.heading(NotesEditCopy.sectionTitle(kind))
    }

    // MARK: - Building

    /// The editor's first text: its lines, then an empty line to type in.
    static func document(_ lines: [NotesEditInitialLineModel], tokens: NotesTokenStore, renderer: any NotesTokenRenderer) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for line in lines {
            text.append(self.line(line, tokens: tokens, renderer: renderer))
            text.append(NSAttributedString(string: newline, attributes: baseAttributes))
        }
        return text
    }

    /// One line, without its line break.
    static func line(_ line: NotesEditInitialLineModel, tokens: NotesTokenStore, renderer: any NotesTokenRenderer) -> NSAttributedString {
        switch line {
        case .heading(let kind):
            var attributes = baseAttributes
            attributes[.font] = Theme.Typography.nsNotesHeading
            attributes[.foregroundColor] = Theme.Colors.Editor.subtleText
            attributes[.notesHeading] = kind.rawValue
            return NSAttributedString(string: sectionTitle(kind), attributes: attributes)
        case .blank:
            return NSAttributedString()
        case .item(let name, let value, let itemID):
            let text = NSMutableAttributedString(string: "\(name) = ", attributes: baseAttributes)
            switch value {
            case .text(let value):
                text.append(NSAttributedString(string: value, attributes: baseAttributes))
            case .token(let id):
                text.append(token(id, renderer: renderer))
            }
            if let itemID {
                text.addAttribute(.notesItem, value: itemID.uuidString, range: NSRange(location: 0, length: text.length))
            }
            return text
        }
    }

    /// A token's attachment character.
    static func token(_ id: NotesTokenID, renderer: any NotesTokenRenderer) -> NSAttributedString {
        let attachment = NotesTokenAttachment(tokenID: id, renderer: renderer)
        let text = NSMutableAttributedString(attachment: attachment)
        text.addAttributes(baseAttributes, range: NSRange(location: 0, length: text.length))
        return text
    }

    // MARK: - Reading

    /// Each line's range, without its line break; the empty line after a final break counts.
    static func paragraphRanges(of string: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        while true {
            let next = string.range(of: newline, options: [], range: NSRange(location: start, length: string.length - start))
            guard next.location != NSNotFound else {
                ranges.append(NSRange(location: start, length: string.length - start))
                return ranges
            }
            ranges.append(NSRange(location: start, length: next.location - start))
            start = next.location + 1
        }
    }

    /// The text as the analysis reads it.
    static func paragraphs(of text: NSAttributedString) -> [NotesParagraphModel] {
        paragraphRanges(of: text.string as NSString).map { range in
            var paragraph = NotesParagraphModel(text: (text.string as NSString).substring(with: range))
            guard range.length > 0 else { return paragraph }
            if let kind = text.attribute(.notesHeading, at: range.location, effectiveRange: nil) as? String {
                paragraph.heading = ConfigKind(rawValue: kind)
            }
            paragraph.tokens = tokens(in: text, range: range).map(\.id)
            text.enumerateAttribute(.notesItem, in: range) { value, _, stop in
                if let id = (value as? String).flatMap(ConfigItemID.init(uuidString:)) {
                    paragraph.itemID = id
                    stop.pointee = true
                }
            }
            return paragraph
        }
    }

    /// The tokens of `text` in `range`, in order.
    static func tokens(in text: NSAttributedString, range: NSRange) -> [(id: NotesTokenID, range: NSRange)] {
        var tokens: [(NotesTokenID, NSRange)] = []
        text.enumerateAttribute(.attachment, in: range) { value, range, _ in
            if let token = value as? NotesTokenAttachment {
                tokens.append((token.tokenID, range))
            }
        }
        return tokens
    }

    /// Plain text for the pasteboard: a token is `••••`, whatever it holds.
    static func plainText(of fragment: NSAttributedString) -> String {
        let text = NSMutableString(string: fragment.string)
        for token in tokens(in: fragment, range: NSRange(location: 0, length: fragment.length)).reversed() {
            text.replaceCharacters(in: token.range, with: NotesCopy.maskToken)
        }
        return text as String
    }
}
