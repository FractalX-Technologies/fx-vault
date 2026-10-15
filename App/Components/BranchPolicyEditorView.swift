import SwiftUI
import VaultCore
import VaultData

/// BranchPolicyEditor (§10 `EnvironmentSettingsScreen`, M4): which branches and tags may deploy
/// to the environment. Labelled blocks over a ``BranchPolicyFormModel`` binding, laid out for
/// ``ConfigEditorSheet``: the choice as a radio group, then the rules in a hairline card with the
/// add row (type, mono pattern field, Add Rule) under it.
struct BranchPolicyEditorView: View {
    @Binding var form: BranchPolicyFormModel
    let isEnabled: Bool
    @FocusState private var isPatternFocused: Bool

    var body: some View {
        ConfigSheetField(String(localized: "branchPolicy.header", defaultValue: "Deployment Branches and Tags")) {
            Picker(selection: $form.choice) {
                ForEach(BranchPolicyFormModel.Choice.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            } label: {
                Text(String(localized: "branchPolicy.header", defaultValue: "Deployment Branches and Tags"))
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(!isEnabled)
            if let warning = form.warning {
                ConfigEditorNoteView(note: warning)
            }
        }

        if form.choice == .selected {
            ConfigSheetField(String(localized: "branchPolicy.rules.header", defaultValue: "Rules")) {
                if !form.patterns.isEmpty {
                    patternList
                }
                addRow
                if let note = form.newPatternNote {
                    ConfigEditorNoteView(note: note)
                } else if form.hasUnaddedPattern {
                    ConfigEditorNoteView(note: .info(String(
                        localized: "branchPolicy.pattern.unadded",
                        defaultValue: "Press Return or Add Rule to add this rule, or clear the field."
                    )))
                }
                Text(String(
                    localized: "branchPolicy.rules.footer",
                    defaultValue: "Patterns use fnmatch syntax, for example release/* for branches or v* for tags."
                ))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.subtleText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var patternList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(form.patterns.enumerated()), id: \.element) { index, pattern in
                if index > 0 {
                    HairlineDivider()
                }
                HStack(spacing: Theme.Spacing.small) {
                    StatusChip.tag(pattern.type.policyEditorTitle)
                    Text(pattern.pattern)
                        .fxTextStyle(.monoName)
                        .foregroundStyle(Theme.Colors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        form.removePattern(pattern)
                    } label: {
                        Label(
                            String(localized: "branchPolicy.pattern.remove.accessibility", defaultValue: "Remove \(pattern.pattern)"),
                            systemImage: "minus.circle"
                        )
                    }
                    .fxIconButtonStyle(.ghost)
                    .disabled(!isEnabled)
                    .help(String(localized: "branchPolicy.pattern.remove", defaultValue: "Remove this rule"))
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.vertical, Theme.Spacing.xSmall)
            }
        }
        .fxCardBackground(.container)
    }

    private var addRow: some View {
        HStack(spacing: Theme.Spacing.small) {
            SegmentedPill(
                selection: $form.newPatternType,
                segments: BranchPatternType.allCases.map { .init(value: $0, title: $0.policyEditorTitle) },
                accessibilityLabel: String(localized: "branchPolicy.pattern.type", defaultValue: "Type")
            )
            .fixedSize()
            TextField(
                String(localized: "branchPolicy.pattern.field", defaultValue: "Pattern"),
                text: $form.newPattern,
                prompt: Text(verbatim: "release/*").foregroundStyle(Theme.Colors.subtleText)
            )
            .focused($isPatternFocused)
            .autocorrectionDisabled()
            .labelsHidden()
            .onSubmit { form.addPattern() }
            .fxInputField(.rounded, isFocused: isPatternFocused, isInvalid: form.newPatternNote?.isError ?? false, isMonospaced: true)
            Button(String(localized: "branchPolicy.pattern.add", defaultValue: "Add Rule")) {
                form.addPattern()
            }
            .fxButtonStyle(.outline)
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
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            BranchPolicyEditorView(form: $form, isEnabled: true)
        }
        .padding(Theme.Spacing.xxLarge)
        .frame(width: Theme.Layout.editorSheetWidth)
        .fxSheetBackground()
    }
}

#Preview {
    BranchPolicyEditorPreview()
}
