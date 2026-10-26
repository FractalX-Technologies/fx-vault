import AppKit

/// A paragraph of the notes editor drawn with its glyphs in the middle of each fixed 24 pt line
/// (``NotesEditText/paragraphStyle``), as the gutter and the line notes beside it are.
nonisolated final class NotesLayoutFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: CGPoint(x: point.x, y: point.y - lift), in: context)
    }

    /// From the fixed height, not the line's: a token's chip may make its line a point taller.
    private var lift: CGFloat {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0 else { return 0 }
        let text = paragraph.attributedString
        guard let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
              let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        else { return 0 }
        return NotesEditText.glyphLift(for: font, lineHeight: style.minimumLineHeight)
    }
}

/// Hands TextKit 2 the editor's own fragments.
nonisolated final class NotesLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        NotesLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}
