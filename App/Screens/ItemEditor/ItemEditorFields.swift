import SwiftUI
import VaultCore

/// The value checks shared by the item editors (`ItemEditor/` and, 1.0, the organization item
/// editor): size, emptiness and the D32 trailing-newline notice.
enum ItemValueRules {
    static func normalizedByteCount(_ value: String) -> Int {
        ValueNormalizer.strippingTrailingNewlines(value).utf8.count
    }

    /// True when `newValue` can be saved; nil keeps the current value.
    static func isValid(_ newValue: String?) -> Bool {
        guard let newValue else { return true }
        return (1...Limits.maxValueBytes).contains(normalizedByteCount(newValue))
    }

    /// Feedback under the value editor. `isEmptyAnError`: an empty editor would save an empty
    /// value; `keepsCurrent`: an empty editor keeps the current value (a secret being edited).
    static func notes(for value: String, isEmptyAnError: Bool, keepsCurrent: Bool) -> [ConfigEditorNoteModel] {
        let byteCount = normalizedByteCount(value)
        var notes: [ConfigEditorNoteModel] = []
        if byteCount > Limits.maxValueBytes {
            notes.append(.error(ValidationError.valueTooLarge(limit: Limits.maxValueBytes).localizedMessage))
        } else if !value.isEmpty, byteCount == 0 {
            notes.append(.error(ValidationError.emptyValue.localizedMessage))
        } else if isEmptyAnError, value.isEmpty {
            notes.append(.error(ValidationError.emptyValue.localizedMessage))
        }
        if byteCount != value.utf8.count {
            notes.append(.info(String(
                localized: "itemEditor.value.trailingNewlines",
                defaultValue: "Trailing line breaks are removed when you save. GitHub removes them too, so FX Vault stores the value as GitHub will."
            )))
        }
        if keepsCurrent, value.isEmpty {
            notes.append(.info(String(
                localized: "itemEditor.value.keep",
                defaultValue: "Leave the value empty to keep the current one."
            )))
        }
        return notes
    }
}

/// The editable name of the item editors: mono, its live note, and a suggested fix.
struct ItemNameField: View {
    @Binding var name: String
    let note: ConfigEditorNoteModel?
    let suggestion: String?
    let isEnabled: Bool
    let onUseSuggestion: () -> Void
    @FocusState private var isFocused: Bool

    private static var label: String {
        String(localized: "itemEditor.name", defaultValue: "Name")
    }

    var body: some View {
        TextField(
            Self.label,
            text: $name,
            prompt: Text(verbatim: "API_TOKEN").foregroundStyle(Theme.Colors.subtleText)
        )
        .focused($isFocused)
        .autocorrectionDisabled()
        .labelsHidden()
        .fxInputField(
            .rounded,
            isFocused: isFocused,
            isInvalid: note?.isError ?? false,
            isMonospaced: true
        )
        .disabled(!isEnabled)
        .accessibilityIdentifier(AccessibilityID.ItemEditor.name)
        if let note {
            ConfigEditorNoteView(note: note)
        }
        if let suggestion {
            HStack(spacing: Theme.Spacing.small) {
                Text(String(localized: "itemEditor.name.suggestion", defaultValue: "Suggested: \(suggestion)"))
                    .fxTextStyle(.monoMeta)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .textSelection(.enabled)
                Spacer()
                Button(String(localized: "itemEditor.name.useSuggestion", defaultValue: "Use Suggestion"), action: onUseSuggestion)
                    .fxButtonStyle(.outline)
            }
        }
    }
}

/// A name that cannot change here: mono in a quiet rounded frame, selectable.
struct ItemEditorReadOnlyName: View {
    let name: String

    var body: some View {
        Text(verbatim: name)
            .fxTextStyle(.mono)
            .foregroundStyle(Theme.Colors.ink)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Theme.Spacing.large)
            .frame(maxWidth: .infinity, minHeight: Theme.Layout.inputHeight, alignment: .leading)
            .background(Theme.Colors.surface, in: Self.shape)
            .overlay(Self.shape.strokeBorder(Theme.Colors.hairline, lineWidth: Theme.Stroke.hairline))
    }

    private static let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
}

/// The credential-looking-variable warning (§5.13) with its "make it a secret" action.
struct CredentialWarningView: View {
    let warning: CredentialWarningModel
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ConfigEditorNoteView(note: .warning(String(
                localized: "itemEditor.credential.title",
                defaultValue: "This looks like a credential. Variable values are stored in plain text on GitHub; keep it as a secret instead."
            )))
            ForEach(warning.reasons, id: \.self) { reason in
                Text(reason)
                    .fxTextStyle(.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = warning.action {
                Button(action == .switchToSecret
                    ? String(localized: "itemEditor.credential.makeSecret", defaultValue: "Make It a Secret")
                    : String(localized: "itemEditor.credential.convert", defaultValue: "Convert to Secret…")) {
                        onAction()
                    }
                    .fxButtonStyle(.outline)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface2, in: Self.shape)
        .overlay(Self.shape.strokeBorder(Theme.Colors.hairlineStrong, lineWidth: Theme.Stroke.hairline))
    }

    private static let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
}

/// Filling a secret GitHub never returned (§7.8): "Already matches GitHub (don't push)", or the
/// next Sync pushes the value.
struct ItemFillChoiceField: View {
    @Binding var matchesGitHub: Bool

    static var label: String {
        String(localized: "itemEditor.fill.header", defaultValue: "On GitHub")
    }

    var body: some View {
        ConfigSheetField(Self.label) {
            FXCheckboxRow(
                title: String(localized: "itemEditor.fill.matchesGitHub", defaultValue: "Already matches GitHub (don't push)"),
                isOn: $matchesGitHub
            )
            ConfigEditorNoteView(note: .info(matchesGitHub
                ? String(
                    localized: "itemEditor.fill.matchesGitHub.note",
                    defaultValue: "Only when you are sure GitHub has exactly this value. Nothing is pushed."
                )
                : String(
                    localized: "itemEditor.fill.pushes.note",
                    defaultValue: "The next Sync replaces the secret on GitHub with this value, so GitHub matches FX Vault."
                )))
        }
    }
}
