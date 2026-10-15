import SwiftUI
import VaultCore
import VaultData

/// BranchPolicyEditor (§10 `EnvironmentSettingsScreen`, M4): which branches and tags may deploy
/// to the environment. Form sections over a ``BranchPolicyFormModel`` binding.
struct BranchPolicyEditorView: View {
    @Binding var form: BranchPolicyFormModel
    let isEnabled: Bool

    var body: some View {
        Section {
            Picker(selection: $form.choice) {
                ForEach(BranchPolicyFormModel.Choice.allCases, id: \.self) { choice in
                    Text(choice.title).tag(choice)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(!isEnabled)
            if let warning = form.warning {
                ConfigEditorNoteView(note: warning)
            }
        } header: {
            Text(String(localized: "branchPolicy.header", defaultValue: "Deployment Branches and Tags"))
        }

        if form.choice == .selected {
            Section {
                ForEach(form.patterns, id: \.self) { pattern in
                    HStack(spacing: Theme.Spacing.small) {
                        StatusChip(title: pattern.type.policyEditorTitle, tint: Theme.Colors.accent)
                        Text(pattern.pattern)
                            .font(Theme.Typography.monospaced)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            form.removePattern(pattern)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!isEnabled)
                        .help(String(localized: "branchPolicy.pattern.remove", defaultValue: "Remove this rule"))
                        .accessibilityLabel(String(
                            localized: "branchPolicy.pattern.remove.accessibility",
                            defaultValue: "Remove \(pattern.pattern)"
                        ))
                    }
                }
                HStack(spacing: Theme.Spacing.small) {
                    Picker(String(localized: "branchPolicy.pattern.type", defaultValue: "Type"), selection: $form.newPatternType) {
                        ForEach(BranchPatternType.allCases, id: \.self) { type in
                            Text(type.policyEditorTitle).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    TextField(
                        String(localized: "branchPolicy.pattern.field", defaultValue: "Pattern"),
                        text: $form.newPattern,
                        prompt: Text(verbatim: "release/*")
                    )
                    .font(Theme.Typography.monospaced)
                    .autocorrectionDisabled()
                    .labelsHidden()
                    .onSubmit { form.addPattern() }
                    Button(String(localized: "branchPolicy.pattern.add", defaultValue: "Add Rule")) {
                        form.addPattern()
                    }
                    .disabled(!form.canAddPattern)
                }
                .disabled(!isEnabled)
                if let note = form.newPatternNote {
                    ConfigEditorNoteView(note: note)
                } else if form.hasUnaddedPattern {
                    ConfigEditorNoteView(note: .info(String(
                        localized: "branchPolicy.pattern.unadded",
                        defaultValue: "Press Return or Add Rule to add this rule, or clear the field."
                    )))
                }
            } header: {
                Text(String(localized: "branchPolicy.rules.header", defaultValue: "Rules"))
            } footer: {
                Text(String(
                    localized: "branchPolicy.rules.footer",
                    defaultValue: "Patterns use fnmatch syntax, for example release/* for branches or v* for tags."
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
    }
}

/// Hosts the editor over local state (previews only).
private struct BranchPolicyEditorPreview: View {
    @State private var form = BranchPolicyFormModel(.custom([
        BranchPatternDraftModel(pattern: "release/*", type: .branch),
        BranchPatternDraftModel(pattern: "v*", type: .tag),
    ]))

    var body: some View {
        Form {
            BranchPolicyEditorView(form: $form, isEnabled: true)
        }
        .formStyle(.grouped)
        .frame(width: Theme.Layout.editorSheetWidth)
    }
}

#Preview {
    BranchPolicyEditorPreview()
}
