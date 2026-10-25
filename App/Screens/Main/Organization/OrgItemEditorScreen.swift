import SwiftUI
import VaultCore

/// The organization item editor (1.0, board Org-Visibility): kind and name on add, the value, and
/// Access (All / Private / Selected with the organization's repositories). Entry view for
/// `MainSheet.orgItemEditor`.
struct OrgItemEditorScreen: View {
    @State private var viewModel: OrgItemEditorViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: OrgItemEditorContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: OrgItemEditorViewModel(context: context, dependencies: dependencies))
    }

    /// A screen over an existing view model (snapshots).
    init(viewModel: OrgItemEditorViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigEditorSheet(
            eyebrow: OrganizationCopy.eyebrow,
            title: viewModel.title,
            subtitle: viewModel.subtitle,
            primaryTitle: viewModel.primaryTitle,
            isPrimaryEnabled: viewModel.canSave,
            isWorking: false,
            onCancel: close,
            onPrimary: save
        ) {
            switch viewModel.loadState {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            case .unavailable(let error):
                Banner(.danger, message: error.message)
            case .ready:
                OrgItemEditorForm(viewModel: viewModel)
            }
        }
        .task { await viewModel.load() }
        .onDisappear { viewModel.clearValue() }
        .screenCaptureProtected()
        .errorAlert($viewModel.alert)
    }

    private func save() {
        if viewModel.save() {
            dismiss()
        }
    }

    private func close() {
        viewModel.clearValue()
        dismiss()
    }
}

private struct OrgItemEditorForm: View {
    @Bindable var viewModel: OrgItemEditorViewModel

    private static var kindLabel: String {
        String(localized: "itemEditor.kind", defaultValue: "Kind")
    }

    var body: some View {
        if viewModel.isAdding {
            ConfigSheetField(Self.kindLabel) {
                SegmentedPill(
                    selection: $viewModel.kind,
                    segments: ConfigKind.allCases.map { .init(value: $0, title: $0.editorTitle) },
                    accessibilityLabel: Self.kindLabel
                )
            }
        }
        ConfigSheetField(String(localized: "itemEditor.name", defaultValue: "Name")) {
            if viewModel.isAdding {
                ItemNameField(
                    name: $viewModel.name,
                    note: viewModel.nameNote,
                    suggestion: viewModel.suggestedName,
                    isEnabled: true,
                    onUseSuggestion: viewModel.applySuggestedName
                )
            } else {
                ItemEditorReadOnlyName(name: viewModel.name)
            }
        }
        ConfigSheetField(String(localized: "itemEditor.value", defaultValue: "Value")) {
            SecretValueEditor(value: $viewModel.value)
            ForEach(viewModel.valueNotes, id: \.self) { note in
                ConfigEditorNoteView(note: note)
            }
            if let warning = viewModel.credentialWarning {
                CredentialWarningView(warning: warning) {
                    viewModel.kind = .secret
                }
            }
        }
        if viewModel.offersFillChoice {
            ItemFillChoiceField(matchesGitHub: $viewModel.matchesGitHub)
        }
        accessField
    }

    private var accessField: some View {
        ConfigSheetField(OrganizationCopy.access) {
            SegmentedPill(
                selection: $viewModel.visibility,
                segments: OrgVisibility.allCases.map { .init(value: $0, title: $0.accessTitle) },
                accessibilityLabel: OrganizationCopy.access
            )
            Text(viewModel.visibility.title(selectedCount: nil))
                .fxTextStyle(.caption)
                .foregroundStyle(Theme.Colors.mutedText)
            if viewModel.visibility == .selected {
                if viewModel.repositoryOptions.isEmpty {
                    ConfigEditorNoteView(note: .info(OrganizationCopy.noRepositories))
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        ForEach(viewModel.repositoryOptions, id: \.self) { name in
                            FXCheckboxRow(title: name, isOn: Binding(
                                get: { viewModel.selectedRepositories.contains(name) },
                                set: { viewModel.setRepository(name, selected: $0) }
                            ))
                        }
                    }
                }
            }
            if let note = viewModel.accessNote {
                ConfigEditorNoteView(note: note)
            }
        }
    }
}
