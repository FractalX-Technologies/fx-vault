import SwiftUI
import VaultCore

/// Set value… (board Place-SecretValue): the value of a secret, or of a variable with line
/// breaks, typed, pasted or generated outside the notes' text. Done sets it on the line's token;
/// closing the popover any other way drops what was typed.
struct NotesValuePopover: View {
    let request: NotesValueRequestModel
    /// A GitHub place: a new secret's line can still become a variable.
    let hasVariables: Bool
    let session: NotesEditSession
    let onClose: () -> Void
    @State private var text: String
    @State private var kind: ConfigKind

    init(
        request: NotesValueRequestModel,
        initialText: String,
        hasVariables: Bool,
        session: NotesEditSession,
        onClose: @escaping () -> Void
    ) {
        self.request = request
        self.hasVariables = hasVariables
        self.session = session
        self.onClose = onClose
        _text = State(initialValue: initialText)
        _kind = State(initialValue: request.kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(verbatim: request.name.isEmpty ? NotesEditCopy.newValueTitle : NotesEditCopy.valueTitle(request.name))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            SecretValueEditor(value: $text, focusesOnAppear: true)
            HStack(spacing: Theme.Spacing.small) {
                // A user-initiated clipboard read: FX Vault never reads the pasteboard by itself.
                PasteButton(payloadType: String.self) { @Sendable strings in
                    Task { @MainActor in
                        text = strings.joined(separator: "\n")
                    }
                }
                .controlSize(.small)
                Button(NotesEditCopy.generate) {
                    text = NotesValueGenerator.value()
                }
                .fxButtonStyle(.outline, size: .compact)
                .help(NotesEditCopy.generateHelp)
            }
            if hasVariables && request.kind == .secret {
                kindPicker
            }
            if request.keepsCurrentValue {
                Text(NotesEditCopy.keepsCurrentValue)
                    .fxTextStyle(.formNote)
                    .foregroundStyle(Theme.Colors.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(NotesEditCopy.done, action: done)
                    .fxButtonStyle(.primary, size: .compact)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier(AccessibilityID.Place.notesValueDone)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: Theme.Layout.notesValuePopoverWidth)
        .onDisappear {
            text = ""
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.smallMinus) {
            HStack {
                Text(NotesEditCopy.kind)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                Spacer()
                SegmentedPill(
                    selection: $kind,
                    segments: [
                        .init(value: ConfigKind.secret, title: NotesEditCopy.kindTitle(.secret)),
                        .init(value: ConfigKind.variable, title: NotesEditCopy.kindTitle(.variable)),
                    ],
                    accessibilityLabel: NotesEditCopy.kind,
                    size: .small
                )
                .fixedSize()
                .disabled(!request.isNew)
            }
            Text(NotesEditCopy.kindFixedAfterSync)
                .fxTextStyle(.formNote)
                .foregroundStyle(Theme.Colors.subtleText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func done() {
        let value = SecretValueEditor.committedValue(text).value
        text = ""
        if kind == .variable && request.kind == .secret {
            session.moveToVariables(request.id, text: value)
        } else {
            session.commitValue(value, for: request.id)
        }
        onClose()
    }
}
