import SwiftUI
import VaultCore

/// A place's notes while they are edited (1.0 N2; boards Place-Edit, Place-Errors, Place-Paste):
/// the editor's lines with their gutter, notes and underlines, the items removed so far, then a
/// repository's organization items, read only as in the notes.
struct NotesEditorView: View {
    @Bindable var session: NotesEditSession
    let reveal: NotesRevealModel
    let changedTitle: String

    var body: some View {
        let lineCount = session.layout.lines.count
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NotesEditorLines(session: session, changedTitle: changedTitle)
                ForEach(session.analysis.plan.removals) { origin in
                    NotesRemovedLine(origin: origin) {
                        session.restore(origin)
                    }
                }
                if let inherited = session.inherited {
                    ForEach(Self.inheritedLines(inherited, after: lineCount)) { line in
                        NotesLineView(line: line, reveal: reveal, changedTitle: changedTitle)
                    }
                }
            }
            .padding(.bottom, Theme.Spacing.smallMinus)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fxCardBackground(.container)
        .overlay(alignment: .bottom) {
            NotesToast(message: $session.toast)
        }
        .sheet(item: $session.review) { review in
            NotesReviewSheet(review: review, session: session)
        }
        .errorAlert($session.alert)
    }

    /// The organization's section after a blank line, numbered on from the editor's lines.
    static func inheritedLines(_ section: NotesSectionModel, after lineCount: Int) -> [NotesLineModel] {
        let blank = NotesLineModel(id: .blank(0), number: lineCount + 1, content: .blank)
        return [blank] + NotesDocumentModel(sections: [section]).lines.map { line in
            NotesLineModel(id: line.id, number: lineCount + 1 + line.number, content: line.content)
        }
    }
}

/// The text view, with what SwiftUI draws around it at the lines' frames: the caret's line,
/// the gutter, the headings' counts, the line notes and the wavy underlines.
private struct NotesEditorLines: View {
    let session: NotesEditSession
    let changedTitle: String

    var body: some View {
        let layout = session.layout
        let lines = session.analysis.lines
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .topLeading) {
                ForEach(layout.lines.indices, id: \.self) { index in
                    NotesGutter(number: index + 1, mark: lines.indices.contains(index) ? lines[index].mark : nil, changedTitle: changedTitle)
                        .frame(height: NotesEditText.lineHeight)
                        .offset(y: layout.lines[index].minY)
                }
            }
            .frame(width: Theme.Layout.notesGutterWidth, alignment: .topLeading)
            NotesTextViewRepresentable(session: session)
                .frame(height: max(layout.height, NotesEditText.lineHeight))
                .overlay(alignment: .topLeading) {
                    NotesEditDecorations(layout: layout, lines: lines)
                }
        }
        .frame(height: max(layout.height, NotesEditText.lineHeight), alignment: .top)
        .background(alignment: .topLeading) {
            if let caret = layout.caretLine, layout.lines.indices.contains(caret) {
                Rectangle()
                    .fill(Theme.Colors.surface)
                    .frame(height: layout.lines[caret].height)
                    .offset(y: layout.lines[caret].minY)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The headings' counts, the line notes and the underlines, in the text view's coordinates.
private struct NotesEditDecorations: View {
    let layout: NotesEditLayoutModel
    let lines: [NotesEditLineModel]

    var body: some View {
        let noteStart = layout.lines.first?.maxX ?? 0
        let noteWidth = max(0, layout.width - noteStart - Theme.Spacing.large)
        ZStack(alignment: .topLeading) {
            ForEach(sectionCounts.sorted { $0.key < $1.key }, id: \.key) { entry in
                if let end = layout.headingEnds[entry.key], layout.lines.indices.contains(entry.key) {
                    Text(verbatim: NotesEditCopy.sectionCount(entry.value))
                        .fxTextStyle(.monoName)
                        .italic()
                        .foregroundStyle(Theme.Colors.subtleText)
                        .fixedSize()
                        .frame(height: NotesEditText.lineHeight)
                        .offset(x: end, y: layout.lines[entry.key].minY)
                }
            }
            ForEach(lines.indices, id: \.self) { index in
                if let note = lines[index].note, layout.lines.indices.contains(index), noteWidth > 0 {
                    NotesEditNote(note: note)
                        .frame(width: noteWidth, height: NotesEditText.lineHeight, alignment: .trailing)
                        .offset(x: noteStart, y: layout.lines[index].minY)
                }
            }
            ForEach(layout.squiggles.indices, id: \.self) { index in
                NotesSquiggle(wavelength: Theme.Layout.notesSquiggleWavelength)
                    .stroke(Theme.Colors.danger, lineWidth: Theme.Stroke.hairline)
                    .frame(width: layout.squiggles[index].width, height: Theme.Layout.notesSquiggleAmplitude * 2)
                    .offset(x: layout.squiggles[index].minX, y: squiggleTop(layout.squiggles[index]))
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Just under the name's descenders, which the fixed line centres.
    private func squiggleTop(_ line: CGRect) -> CGFloat {
        line.minY + NotesEditText.lineHeight - NotesEditText.glyphLift(for: Theme.Typography.nsNotes, lineHeight: NotesEditText.lineHeight)
    }

    /// Each heading's item lines, by the heading's paragraph.
    private var sectionCounts: [Int: Int] {
        var counts: [Int: Int] = [:]
        var heading: Int?
        for (index, line) in lines.enumerated() {
            switch line.role {
            case .heading:
                heading = index
                counts[index] = 0
            case .item:
                if let heading {
                    counts[heading, default: 0] += 1
                }
            case .blank, .comment:
                break
            }
        }
        return counts
    }
}

/// A line's note at its trailing edge: what changed in subtle text, or why it can't be saved
/// in red after a dot (board Place-Errors).
private struct NotesEditNote: View {
    let note: NotesEditNoteModel

    var body: some View {
        HStack(spacing: Theme.Spacing.smallMinus) {
            if note.isError {
                Circle()
                    .fill(Theme.Colors.danger)
                    .frame(width: Theme.Layout.notesErrorDotSize, height: Theme.Layout.notesErrorDotSize)
                    .accessibilityHidden(true)
            }
            Text(note.text)
                .fxTextStyle(.caption)
                .foregroundStyle(note.isError ? Theme.Colors.danger : Theme.Colors.subtleText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(note.text)
        }
    }
}

/// The wavy underline of a name a line can't save.
private nonisolated struct NotesSquiggle: Shape {
    let wavelength: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX
        path.move(to: CGPoint(x: x, y: rect.midY))
        var isUp = true
        while x < rect.maxX {
            let next = min(x + wavelength / 2, rect.maxX)
            path.addQuadCurve(
                to: CGPoint(x: next, y: rect.midY),
                control: CGPoint(x: (x + next) / 2, y: isUp ? rect.minY : rect.maxY)
            )
            x = next
            isUp.toggle()
        }
        return path
    }
}

/// An item whose line is gone from the text (board Place-Edit): struck through, with Undo,
/// which puts its line back at the end of its section.
private struct NotesRemovedLine: View {
    let origin: NotesEditOriginModel
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: Theme.Layout.notesGutterWidth)
            Text(verbatim: "\(origin.name) = \(origin.text ?? NotesCopy.maskToken)")
                .fxTextStyle(.monoName)
                .strikethrough()
                .foregroundStyle(Theme.Colors.subtleText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Spacing.medium)
            Text(verbatim: "\(NotesEditCopy.removedNote) ·")
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.subtleText)
                .padding(.trailing, Theme.Spacing.xSmall)
            Button(NotesEditCopy.undo, action: restore)
                .fxInkLinkButtonStyle()
                .accessibilityLabel(NotesEditCopy.restore(origin.name))
        }
        .padding(.trailing, Theme.Spacing.large)
        .frame(height: NotesEditText.lineHeight)
        .accessibilityElement(children: .contain)
    }
}

/// "3 values set from the clipboard · clipboard cleared" (board Place-Paste), for a few seconds.
private struct NotesToast: View {
    @Binding var message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let message {
                Label(message, systemImage: "checkmark")
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.onInk)
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.vertical, Theme.Spacing.small)
                    .background(Theme.Colors.ink, in: .capsule)
                    .padding(.bottom, Theme.Spacing.large)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task(id: message) {
                        AccessibilityNotification.Announcement(message).post()
                        do {
                            try await Task.sleep(for: Theme.Durations.notesToast)
                        } catch {
                            // Another paste's toast replaced this one: it keeps its own time.
                            return
                        }
                        self.message = nil
                    }
            }
        }
        .animation(Theme.Durations.spring, value: message)
    }
}

/// The editor in SwiftUI: its height follows the text (``NotesEditLayoutModel/height``).
private struct NotesTextViewRepresentable: NSViewRepresentable {
    let session: NotesEditSession

    func makeNSView(context: Context) -> NotesTextView {
        NotesTextView(session: session)
    }

    func updateNSView(_ textView: NotesTextView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NotesTextView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: proposal.height ?? nsView.frame.height)
    }
}
