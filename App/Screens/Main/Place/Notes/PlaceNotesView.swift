import SwiftUI
import VaultCore

/// A place's notes (1.0 B9; boards Main2-Repository, Place-Reveal, KV-Place): numbered
/// `KEY = value` lines in sections, secrets as masked tokens until revealed (after Touch ID or
/// the master password), variables in plaintext, the ○ / ● marks in the gutter and each line's
/// note at its trailing edge. Read only; where they can be edited, a click on a line of the
/// place's own starts an edit there (1.0 N2). While Reveal All shows the secrets, its countdown
/// sits above the lines and a click copies a line's value instead.
struct PlaceNotesView<Model: NotesPlaceModel>: View {
    let model: Model
    /// Starts an edit at line N (from 1); nil where the notes can't be edited.
    var onEdit: ((Int) -> Void)?

    var body: some View {
        let reveal = model.notesReveal
        let changedTitle = model.changedAtSourceTitle
        let revealAllHideDate = reveal.revealAllHideDate
        VStack(alignment: .leading, spacing: 0) {
            if let revealAllHideDate {
                NotesRevealAllBar(hideDate: revealAllHideDate)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.notes.lines) { line in
                        NotesLineView(
                            line: line,
                            reveal: reveal,
                            changedTitle: changedTitle,
                            onEdit: revealAllHideDate == nil ? edit(line) : nil,
                            onCopy: revealAllHideDate == nil ? nil : copy(line)
                        )
                    }
                }
                .padding(.vertical, Theme.Spacing.smallMinus)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fxCardBackground(.container)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NotesCopy.accessibilityLabel(place: model.notesPlaceName))
        .accessibilityIdentifier(AccessibilityID.Place.notes)
    }

    private func edit(_ line: NotesLineModel) -> (() -> Void)? {
        onEdit.flatMap { edit in line.isInherited ? nil : { edit(line.number) } }
    }

    private func copy(_ line: NotesLineModel) -> (() -> Void)? {
        guard case .item(let item) = line.content, item.canCopy else { return nil }
        return { model.copy(item.id) }
    }
}

/// Reveal All's countdown above the notes, and what a click on a line does meanwhile.
private struct NotesRevealAllBar: View {
    let hideDate: Date

    var body: some View {
        HStack(spacing: Theme.Spacing.medium) {
            NotesRevealCountdown(hideDate: hideDate, total: Timeouts.revealAllRemask)
            Spacer(minLength: 0)
            Text(NotesCopy.clickToCopy)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.subtleText)
                .lineLimit(1)
        }
        .padding(.leading, Theme.Layout.notesGutterWidth)
        .padding(.trailing, Theme.Spacing.large)
        .frame(height: Theme.Layout.notesLineHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Colors.hairline)
                .frame(height: Theme.Stroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Place.revealAllBar)
    }
}

/// One line: the gutter, then a heading, nothing (a blank line) or `KEY = value` with its note.
struct NotesLineView: View {
    let line: NotesLineModel
    let reveal: NotesRevealModel
    let changedTitle: String
    /// A click on the line: an edit of the notes from it; nil where they can't be edited.
    var onEdit: (() -> Void)?
    /// A click on the line while Reveal All shows the values: a copy of its value. It wins over
    /// ``onEdit``.
    var onCopy: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            NotesGutter(number: line.number, mark: item?.mark, changedTitle: changedTitle)
            content
            Spacer(minLength: Theme.Spacing.medium)
            trailing
        }
        .padding(.trailing, Theme.Spacing.large)
        .frame(height: isRevealedAlone ? Theme.Layout.notesRevealedLineHeight : Theme.Layout.notesLineHeight)
        .background(isRevealedAlone ? Theme.Colors.surface2 : Color.clear)
        .accessibilityElement(children: .contain)
        .modifier(NotesLineClickGesture(onEdit: onEdit, onCopy: onCopy, number: line.number))
    }

    private var item: NotesItemLineModel? {
        if case .item(let item) = line.content { item } else { nil }
    }

    private var isRevealed: Bool {
        if case .revealed = item?.value { true } else { false }
    }

    /// Revealed on its own, with its countdown: the band and the taller line of board
    /// Place-Reveal. Under Reveal All the lines stay plain note lines.
    private var isRevealedAlone: Bool {
        guard let item, isRevealed else { return false }
        return reveal.hideDate(of: item.id) != nil
    }

    @ViewBuilder
    private var content: some View {
        switch line.content {
        case .heading(let title):
            Text(verbatim: NotesCopy.heading(title))
                .fxTextStyle(.monoName)
                .italic()
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityAddTraits(.isHeader)
        case .blank:
            EmptyView()
        case .item(let item):
            HStack(spacing: Theme.Spacing.smallMinus) {
                Text(verbatim: item.name)
                    .fxTextStyle(.monoName)
                    .foregroundStyle(item.isInherited ? Theme.Colors.subtleText : Theme.Colors.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(verbatim: "=")
                    .fxTextStyle(.monoName)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .accessibilityHidden(true)
                NotesValueView(item: item, reveal: reveal)
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let item, onCopy != nil, reveal.copiedID == item.id {
            CopiedLabel()
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.ink)
                .accessibilityIdentifier(AccessibilityID.Place.notesCopied)
        } else if let item, isRevealed, let hideDate = reveal.hideDate(of: item.id) {
            NotesRevealCountdown(hideDate: hideDate) {
                reveal.hide(item.id)
            }
        } else if let note = item?.note {
            Text(note)
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.subtleText)
                .lineLimit(1)
                .help(note)
        }
    }
}

/// Click to copy (Reveal All) or to edit: the pointing hand or the text cursor over the line,
/// and VoiceOver's Copy Value or Edit Notes action.
private struct NotesLineClickGesture: ViewModifier {
    let onEdit: (() -> Void)?
    let onCopy: (() -> Void)?
    let number: Int

    func body(content: Content) -> some View {
        if let onCopy {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: onCopy)
                .pointerStyle(.link)
                .accessibilityAction(named: PlaceCopy.copyValue, onCopy)
                .accessibilityIdentifier(AccessibilityID.Place.notesLine(number))
        } else if let onEdit {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: onEdit)
                .pointerStyle(.horizontalText)
                .accessibilityAction(named: NotesEditCopy.edit, onEdit)
                .accessibilityIdentifier(AccessibilityID.Place.notesLine(number))
        } else {
            content
        }
    }
}

/// The line number, after the ○ (changed at the source) or ● (pending) mark.
struct NotesGutter: View {
    let number: Int
    let mark: NotesMarkModel?
    let changedTitle: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xSmall) {
            switch mark {
            case .changedAtSource:
                RingDot()
                    .help(changedTitle)
            case .pending:
                Circle()
                    .fill(Theme.Colors.ink)
                    .frame(width: Theme.Layout.changedDotSize, height: Theme.Layout.changedDotSize)
                    .help(NotesCopy.pendingMark)
            case nil:
                EmptyView()
            }
            // `subtleText`, not the board's lighter #8A8A8E: faint text fails AA (DESIGN.md).
            Text(number, format: .number.grouping(.never))
                .fxTextStyle(.monoLabel)
                .foregroundStyle(Theme.Colors.subtleText)
                .accessibilityHidden(true)
        }
        .frame(width: Theme.Layout.notesGutterWidth - Theme.Spacing.mediumPlus, alignment: .trailing)
        .padding(.trailing, Theme.Spacing.mediumPlus)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(markTitle ?? "")
        .accessibilityHidden(markTitle == nil)
    }

    private var markTitle: String? {
        switch mark {
        case .changedAtSource: changedTitle
        case .pending: NotesCopy.pendingMark
        case nil: nil
        }
    }
}

/// A value: the masked token (a button that asks to reveal it), the revealed value in an ink
/// outline, a variable in plaintext, or nothing for a secret without a value. The quick vault's
/// lines show it too (1.0 Q1).
struct NotesValueView: View {
    let item: NotesItemLineModel
    let reveal: NotesRevealModel

    var body: some View {
        switch item.value {
        case .masked:
            if item.canReveal {
                Button {
                    reveal.ask(item)
                } label: {
                    maskToken
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(NotesCopy.revealHelp)
                .accessibilityLabel(NotesCopy.reveal(item.name))
            } else {
                maskToken
            }
        case .revealed(let value) where reveal.hideDate(of: item.id) == nil:
            // Reveal All: plain note text, as a variable, so the notes read as a note. Not
            // selectable either (see below); a click on the line copies it.
            Text(verbatim: value)
                .fxTextStyle(.monoName)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.disabled)
        case .revealed(let value):
            // Not selectable: ⌘C, Copy and Services would bypass `ClipboardManager` (no
            // concealed marker, no clear after 30 s or on lock, Universal Clipboard).
            Text(verbatim: value)
                .fxTextStyle(.monoMeta)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.disabled)
                .padding(.horizontal, Theme.Spacing.smallMinus)
                .frame(height: Theme.Layout.notesTokenHeight)
                .overlay(tokenShape.strokeBorder(Theme.Colors.ink, lineWidth: Theme.Stroke.hairline))
        case .plain(let value):
            Text(verbatim: value)
                .fxTextStyle(.monoName)
                .foregroundStyle(item.isInherited ? Theme.Colors.subtleText : Theme.Colors.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
        case .missing:
            EmptyView()
        }
    }

    private var tokenShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.token, style: .continuous)
    }

    @ViewBuilder
    private var maskToken: some View {
        if let file = item.file {
            FileSecretChip.notes(file)
        } else {
            dots
        }
    }

    private var dots: some View {
        Text(verbatim: NotesCopy.maskToken)
            .fxTextStyle(.monoLabel)
            .foregroundStyle(Theme.Colors.mutedText)
            .padding(.horizontal, Theme.Spacing.smallMinus)
            .frame(height: Theme.Layout.notesTokenHeight)
            .background(Theme.Colors.surface2, in: tokenShape)
            .contentShape(tokenShape)
    }
}

/// "▬▬ hides in 30 s · Hide" beside a revealed value (board Place-Reveal); without Hide above
/// Reveal All's lines, where the header's Hide All ends it.
private struct NotesRevealCountdown: View {
    let hideDate: Date
    var total = Timeouts.revealRemask
    var onHide: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(hideDate.timeIntervalSince(context.date).rounded(.up)))
            let fraction = min(1, Double(remaining) / total.timeInterval)
            HStack(spacing: Theme.Spacing.smallMinus) {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.Colors.hairline)
                    Rectangle()
                        .fill(Theme.Colors.ink)
                        .frame(width: Theme.Layout.notesRemaskBarWidth * fraction)
                }
                .frame(width: Theme.Layout.notesRemaskBarWidth, height: Theme.Layout.notesRemaskBarHeight)
                .clipShape(Capsule.pill)
                .animation(reduceMotion ? nil : .linear(duration: 1), value: remaining)
                .accessibilityElement()
                .accessibilityLabel(NotesCopy.hidesInAccessibility(seconds: remaining))
                Text(verbatim: onHide == nil ? NotesCopy.hidesIn(seconds: remaining) : "\(NotesCopy.hidesIn(seconds: remaining)) ·")
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .monospacedDigit()
                    .accessibilityHidden(true)
                if let onHide {
                    Button(NotesCopy.hide, action: onHide)
                        .fxInkLinkButtonStyle()
                }
            }
        }
    }
}

extension View {
    /// "Confirm it's you" before a Reveal or a secret's Copy Value, in the notes or the table: on
    /// the place's screen, so it shows in either mode.
    func notesRevealSheet(_ reveal: NotesRevealModel) -> some View {
        modifier(NotesRevealSheet(reveal: reveal))
    }
}

/// The sheet of ``NotesRevealModel/request``.
private struct NotesRevealSheet: ViewModifier {
    let reveal: NotesRevealModel

    func body(content: Content) -> some View {
        @Bindable var reveal = reveal
        let request = Binding(
            get: { reveal.request },
            set: { if $0 == nil { reveal.cancel() } }
        )
        content
            .sheet(item: request) { request in
                NotesRevealDialog(request: request, reveal: reveal)
            }
            .errorAlert($reveal.alert)
    }
}

private struct NotesRevealDialog: View {
    let request: NotesRevealRequestModel
    let reveal: NotesRevealModel

    var body: some View {
        DialogSheet(title: request.title) {
            if let reauth = reveal.reauth {
                ReauthView(
                    model: reauth,
                    message: request.message,
                    onTouchID: { await reveal.authenticateWithTouchID() },
                    onPassword: { await reveal.authenticateWithPassword() }
                )
            }
        } actions: {
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                reveal.cancel()
            }
            .fxButtonStyle(.outline, size: .dialog)
            .keyboardShortcut(.cancelAction)
        }
        .frame(width: Theme.Layout.sheetWidth)
        .task { await reveal.start() }
    }
}
