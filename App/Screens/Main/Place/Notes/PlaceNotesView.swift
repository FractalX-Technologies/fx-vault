import SwiftUI
import VaultCore

/// A place's notes (1.0 B9; boards Main2-Repository, Place-Reveal, KV-Place): numbered
/// `KEY = value` lines in sections, secrets as masked tokens until revealed (after Touch ID or
/// the master password), variables in plaintext, the ○ / ● marks in the gutter and each line's
/// note at its trailing edge. Read only.
struct PlaceNotesView<Model: NotesPlaceModel>: View {
    let model: Model

    var body: some View {
        let reveal = model.notesReveal
        let changedTitle = model.changedAtSourceTitle
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.notes.lines) { line in
                    NotesLineView(line: line, reveal: reveal, changedTitle: changedTitle)
                }
            }
            .padding(.vertical, Theme.Spacing.smallMinus)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fxCardBackground(.container)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NotesCopy.accessibilityLabel(place: model.notesPlaceName))
        .accessibilityIdentifier(AccessibilityID.Place.notes)
        .modifier(NotesRevealSheet(reveal: reveal))
    }
}

/// One line: the gutter, then a heading, nothing (a blank line) or `KEY = value` with its note.
private struct NotesLineView: View {
    let line: NotesLineModel
    let reveal: NotesRevealModel
    let changedTitle: String

    var body: some View {
        HStack(spacing: 0) {
            NotesGutter(number: line.number, mark: item?.mark, changedTitle: changedTitle)
            content
            Spacer(minLength: Theme.Spacing.medium)
            trailing
        }
        .padding(.trailing, Theme.Spacing.large)
        .frame(height: isRevealed ? Theme.Layout.notesRevealedLineHeight : Theme.Layout.notesLineHeight)
        .background(isRevealed ? Theme.Colors.surface2 : Color.clear)
        .accessibilityElement(children: .contain)
    }

    private var item: NotesItemLineModel? {
        if case .item(let item) = line.content { item } else { nil }
    }

    private var isRevealed: Bool {
        if case .revealed = item?.value { true } else { false }
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
        if let item, isRevealed, let hideDate = reveal.hideDate(of: item.id) {
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

/// The line number, after the ○ (changed at the source) or ● (pending) mark.
private struct NotesGutter: View {
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
/// outline, a variable in plaintext, or nothing for a secret without a value.
private struct NotesValueView: View {
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

    private var maskToken: some View {
        Text(verbatim: NotesCopy.maskToken)
            .fxTextStyle(.monoLabel)
            .foregroundStyle(Theme.Colors.mutedText)
            .padding(.horizontal, Theme.Spacing.smallMinus)
            .frame(height: Theme.Layout.notesTokenHeight)
            .background(Theme.Colors.surface2, in: tokenShape)
            .contentShape(tokenShape)
    }
}

/// "▬▬ hides in 30 s · Hide" beside a revealed value (board Place-Reveal).
private struct NotesRevealCountdown: View {
    let hideDate: Date
    let onHide: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(hideDate.timeIntervalSince(context.date).rounded(.up)))
            let fraction = min(1, Double(remaining) / Timeouts.revealRemask.timeInterval)
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
                Text(verbatim: "\(NotesCopy.hidesIn(seconds: remaining)) ·")
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .monospacedDigit()
                    .accessibilityHidden(true)
                Button(NotesCopy.hide, action: onHide)
                    .fxInkLinkButtonStyle()
            }
        }
    }
}

/// "Confirm it's you" before a Reveal: the sheet of ``NotesRevealModel/request``.
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
        DialogSheet(title: NotesCopy.reveal(request.name)) {
            if let reauth = reveal.reauth {
                ReauthView(
                    model: reauth,
                    message: NotesCopy.revealMessage,
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
