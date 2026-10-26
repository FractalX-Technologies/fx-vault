import SwiftUI
import VaultCore
import VaultData

/// BranchPolicyEditor (§10 `EnvironmentSettingsScreen`, M4; board NewEnvironment): which
/// branches and tags may deploy to the environment, over a ``BranchPolicyFormModel`` binding.
/// The choice as a radio group; for selected branches and tags, a grey box with each rule as a
/// chip (`release/* · branch ×`), the add row (type, mono pattern field, Add Rule) and the fnmatch
/// note. Callers give it its label (a dialog form row or a ``ConfigSheetField``).
struct BranchPolicyEditorView: View {
    @Binding var form: BranchPolicyFormModel
    let isEnabled: Bool
    @FocusState private var isPatternFocused: Bool

    /// The editor's label in the sheets that keep labelled blocks (Environment Settings).
    static var header: String {
        String(localized: "branchPolicy.header", defaultValue: "Deployment Branches and Tags")
    }

    /// Its label in a dialog form's column (board NewEnvironment).
    static var formLabel: String {
        String(localized: "branchPolicy.label", defaultValue: "Deployment branches")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Picker(selection: $form.choice) {
                ForEach(BranchPolicyFormModel.Choice.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            } label: {
                Text(Self.header)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(!isEnabled)
            if let warning = form.warning {
                DialogFormNote(warning.message, tone: warning.dialogTone)
            }
            if form.choice == .selected {
                rules
            }
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if !form.patterns.isEmpty {
                FlowLayout(spacing: Theme.Spacing.smallMinus) {
                    ForEach(form.patterns, id: \.self) { pattern in
                        DialogTokenChip(
                            title: String(
                                localized: "branchPolicy.pattern.chip",
                                defaultValue: "\(pattern.pattern) · \(pattern.type.policyChipTitle)"
                            ),
                            removeLabel: String(localized: "branchPolicy.pattern.remove.accessibility", defaultValue: "Remove \(pattern.pattern)"),
                            onRemove: { form.removePattern(pattern) }
                        )
                        .disabled(!isEnabled)
                    }
                }
            }
            addRow
            if let note = form.newPatternNote {
                DialogFormNote(note.message, tone: note.dialogTone)
            } else if form.hasUnaddedPattern {
                DialogFormNote(String(
                    localized: "branchPolicy.pattern.unadded",
                    defaultValue: "Press Return or Add Rule to add this rule, or clear the field."
                ))
            }
            DialogFormNote(String(
                localized: "branchPolicy.rules.footer",
                defaultValue: "Patterns use fnmatch syntax, for example release/* for branches or v* for tags."
            ))
        }
        .fxDialogListBox()
    }

    private var addRow: some View {
        HStack(spacing: Theme.Spacing.smallMinus) {
            SegmentedPill(
                selection: $form.newPatternType,
                segments: BranchPatternType.allCases.map { .init(value: $0, title: $0.policyEditorTitle) },
                accessibilityLabel: String(localized: "branchPolicy.pattern.type", defaultValue: "Type"),
                size: .small
            )
            .fixedSize()
            TextField(
                String(localized: "branchPolicy.pattern.field", defaultValue: "Pattern"),
                text: $form.newPattern,
                prompt: Text(String(localized: "branchPolicy.pattern.prompt", defaultValue: "Branch or tag pattern"))
                    .foregroundStyle(Theme.Colors.subtleText)
            )
            .focused($isPatternFocused)
            .autocorrectionDisabled()
            .labelsHidden()
            .onSubmit { form.addPattern() }
            .fxInputField(.dialog, isFocused: isPatternFocused, isInvalid: form.newPatternNote?.isError ?? false, isMonospaced: true)
            Button(String(localized: "branchPolicy.pattern.add", defaultValue: "Add Rule")) {
                form.addPattern()
            }
            .fxButtonStyle(.outline, size: .compact)
            .disabled(!form.canAddPattern)
        }
        .disabled(!isEnabled)
    }
}

/// Hosts the editor over local state (previews only).
private struct BranchPolicyEditorPreview: View {
    @State private var form = BranchPolicyFormModel(.custom([
        BranchPatternDraftModel(pattern: "release/*", type: .branch),
        BranchPatternDraftModel(pattern: "v*", type: .tag),
    ]))

    var body: some View {
        DialogFormRow(BranchPolicyEditorView.formLabel) {
            BranchPolicyEditorView(form: $form, isEnabled: true)
        }
        .padding(Theme.Layout.compactSheetInset)
        .frame(width: Theme.Layout.newEnvironmentSheetWidth)
        .fxSheetBackground()
    }
}

#Preview {
    BranchPolicyEditorPreview()
}
