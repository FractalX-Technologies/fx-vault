import AppKit

/// Draws a token in its current state (the edit's ``NotesTokenStore``).
protocol NotesTokenRenderer: AnyObject, Sendable {
    func display(of token: NotesTokenID) -> NotesTokenStore.Display
}

/// A token in the notes editor's text (1.0 N2, anton D3): one character the text, its undo and its
/// pasteboard see, drawn as a chip (`••••`, a value set in this edit, "Set value…", "3 lines"). It holds only the token's id,
/// so undoing a cut or a deletion brings the same token back with its value.
nonisolated final class NotesTokenAttachment: NSTextAttachment {
    let tokenID: NotesTokenID
    private weak var renderer: (any NotesTokenRenderer)?

    @MainActor
    init(tokenID: NotesTokenID, renderer: any NotesTokenRenderer) {
        self.tokenID = tokenID
        self.renderer = renderer
        super.init(data: nil, ofType: nil)
        // Drawn from its image: a view per token is not needed to show a chip.
        allowsTextAttachmentView = false
        // TextKit 2 draws nothing for an attachment without an image: this one stands in, and
        // `image(for:attributes:location:textContainer:)` draws the chip.
        image = NSImage(size: CGSize(width: 1, height: 1))
    }

    required init?(coder: NSCoder) {
        nil
    }

    // The editor lays out on the main thread (TextKit 2 in an `NSTextView`): the edit's state
    // is read there.
    private var display: NotesTokenStore.Display {
        let renderer = renderer
        let tokenID = tokenID
        return MainActor.assumeIsolated {
            renderer?.display(of: tokenID) ?? .setValue
        }
    }

    private func image(size: CGSize) -> NSImage? {
        let display = display
        return MainActor.assumeIsolated {
            NotesTokenDrawing.image(for: display, size: size)
        }
    }

    private var chipBounds: CGRect {
        let display = display
        return MainActor.assumeIsolated {
            NotesTokenDrawing.bounds(for: display)
        }
    }

    // MARK: TextKit 2

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        chipBounds
    }

    override func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSImage? {
        image(size: bounds.size)
    }

    // MARK: TextKit 1 (a fallback AppKit may still take)

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        chipBounds
    }

    override func image(forBounds imageBounds: NSRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> NSImage? {
        image(size: imageBounds.size)
    }
}

/// A token's chip, as N1's read-only notes draw it (board Place-Edit): a filled rounded rectangle,
/// or a dashed one for "Set value…".
enum NotesTokenDrawing {
    private static let height = Theme.Layout.notesEditTokenHeight
    private static let padding = Theme.Spacing.smallMinus
    /// A visible value longer than this keeps its start and end: a token can't wrap.
    static let visibleMaxCharacters = 48

    static func label(for display: NotesTokenStore.Display) -> String {
        switch display {
        case .masked(let oversize?): "\(NotesCopy.maskToken) \(NotesEditCopy.bytes(oversize))"
        case .masked(nil): NotesCopy.maskToken
        case .visible(let value): shortened(value)
        case .setValue: NotesEditCopy.setValueToken
        case .lines(let count): NotesEditCopy.lines(count)
        case .file(let file): FileSecretCopy.notesLabel(file)
        }
    }

    private static func shortened(_ value: String) -> String {
        guard value.count > visibleMaxCharacters else { return value }
        let kept = visibleMaxCharacters - 1
        return "\(value.prefix(kept - kept / 2))…\(value.suffix(kept / 2))"
    }

    private static var labelAttributes: [NSAttributedString.Key: Any] {
        [.font: Theme.Typography.nsNotesToken]
    }

    /// From the text's descent up: a chip reaching lower would make its line taller than the
    /// others (TextKit 2 adds the extra descent under the fixed line).
    static func bounds(for display: NotesTokenStore.Display) -> CGRect {
        let width = (label(for: display) as NSString).size(withAttributes: labelAttributes).width.rounded(.up) + padding * 2
        return CGRect(x: 0, y: Theme.Typography.nsNotes.descender, width: width, height: height)
    }

    static func image(for display: NotesTokenStore.Display, size: CGSize) -> NSImage {
        // Drawn when shown, so the colors follow the view's light or dark appearance.
        let image = NSImage(size: size, flipped: false) { rect in
            draw(display, in: rect)
            return true
        }
        image.cacheMode = .never
        return image
    }

    private static func draw(_ display: NotesTokenStore.Display, in rect: CGRect) {
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.token, yRadius: Theme.Radius.token)
        let textColor: NSColor
        switch display {
        case .visible:
            // The read notes' revealed value: ink text in an ink outline.
            Theme.Colors.Editor.ink.setStroke()
            shape.lineWidth = Theme.Stroke.hairline
            shape.stroke()
            textColor = Theme.Colors.Editor.ink
        case .setValue:
            Theme.Colors.Editor.ink.setStroke()
            shape.lineWidth = Theme.Stroke.hairline
            shape.setLineDash(Theme.Layout.notesTokenDash, count: Theme.Layout.notesTokenDash.count, phase: 0)
            shape.stroke()
            textColor = Theme.Colors.Editor.ink
        case .masked(let oversize):
            Theme.Colors.Editor.surface2.setFill()
            shape.fill()
            textColor = oversize == nil ? Theme.Colors.Editor.mutedText : Theme.Colors.Editor.danger
        case .lines, .file:
            Theme.Colors.Editor.surface2.setFill()
            shape.fill()
            textColor = Theme.Colors.Editor.mutedText
        }
        var attributes = labelAttributes
        attributes[.foregroundColor] = textColor
        let text = label(for: display) as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}
