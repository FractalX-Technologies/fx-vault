import SwiftUI
import VaultCore

/// ConfigItemEditorScreen (§10 Sheets): kind (locked once synced), name (auto-uppercase with
/// live validation and a suggested fix), value in `SecretValueEditor` (D32 notice, SSH/PEM
/// hint), the credential warning for variables, "Already matches GitHub" for value-missing
/// secrets, "Push on Next Sync" for synced secrets, and Convert/Move.
///
/// UI feature contract entry view (ARCHITECTURE.md): presented by `MainScreen` for
/// `MainSheet.itemEditor`. The init signature is fixed. Dismiss with `@Environment(\.dismiss)`.
struct ItemEditorScreen: View {
    @State private var viewModel: ItemEditorViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: ItemEditorContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: ItemEditorViewModel(context: context, dependencies: dependencies))
    }

    /// A screen over an existing view model (previews and snapshots).
    init(viewModel: ItemEditorViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigEditorSheet(
            eyebrow: String(localized: "itemEditor.eyebrow", defaultValue: "Secrets and variables"),
            title: viewModel.title,
            subtitle: viewModel.subtitle,
            primaryTitle: viewModel.primaryTitle,
            isPrimaryEnabled: viewModel.canSave,
            isWorking: viewModel.isSaving,
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
                ItemEditorForm(viewModel: viewModel)
            }
        }
        .task { await viewModel.load() }
        .onDisappear { viewModel.clearValue() }
        .screenCaptureProtected()
        .errorAlert($viewModel.alert)
        .confirmationDialog(
            viewModel.confirmation?.title ?? "",
            isPresented: confirmationBinding,
            titleVisibility: .visible,
            presenting: viewModel.confirmation
        ) { confirmation in
            Button(confirmation.confirmTitle, role: .destructive) {
                if viewModel.confirm() {
                    dismiss()
                }
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {
                viewModel.cancelConfirmation()
            }
            .keyboardShortcut(.defaultAction)
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.confirmation != nil },
            set: { if !$0 { viewModel.cancelConfirmation() } }
        )
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

/// The labelled fields of a loaded editor, by mode.
private struct ItemEditorForm: View {
    @Bindable var viewModel: ItemEditorViewModel

    var body: some View {
        if let reason = viewModel.readOnlyReason {
            Banner(.warning, message: reason.localizedExplanation, systemImage: "lock")
        }
        if viewModel.isMoving {
            moveFields
        } else {
            kindField
            nameField
            valueField
            if viewModel.offersFillChoice {
                fillField
            }
            if viewModel.offersPushOnNextSync || viewModel.isPushAlreadyRequested {
                pushField
            }
            if viewModel.offersLinkedUpdate {
                linkedField
            }
        }
    }

    private static var nameLabel: String {
        String(localized: "itemEditor.name", defaultValue: "Name")
    }

    private static var onGitHubLabel: String {
        ItemFillChoiceField.label
    }

    // MARK: - Kind and name

    private var kindField: some View {
        ConfigSheetField(String(localized: "itemEditor.kind", defaultValue: "Kind")) {
            SegmentedPill(
                selection: $viewModel.kind,
                segments: ConfigKind.allCases.map { .init(value: $0, title: $0.editorTitle) },
                accessibilityLabel: String(localized: "itemEditor.kind", defaultValue: "Kind")
            )
            .disabled(!viewModel.isKindEditable || !viewModel.canEdit)
            if let note = viewModel.kindLockNote {
                ConfigEditorNoteView(note: note)
            }
        }
    }

    @ViewBuilder private var nameField: some View {
        ConfigSheetField(Self.nameLabel) {
            if viewModel.isNameEditable {
                ItemNameField(
                    name: $viewModel.name,
                    note: viewModel.nameNote,
                    suggestion: viewModel.suggestedName,
                    isEnabled: viewModel.canEdit,
                    onUseSuggestion: viewModel.applySuggestedName
                )
            } else {
                ItemEditorReadOnlyName(name: viewModel.item?.name ?? "")
            }
        }
    }

    // MARK: - Value

    private var valueField: some View {
        ConfigSheetField(String(localized: "itemEditor.value", defaultValue: "Value")) {
            if viewModel.isFilling {
                ConfigEditorNoteView(note: .info(String(
                    localized: "itemEditor.fill.explanation",
                    defaultValue: "GitHub never returns secret values. Enter the value this secret has so FX Vault can reveal, copy and export it."
                )))
            }
            SecretValueEditor(value: $viewModel.value)
                .disabled(!viewModel.canEdit)
            ForEach(viewModel.valueNotes, id: \.self) { note in
                ConfigEditorNoteView(note: note)
            }
            if viewModel.canLoadCurrentValue {
                Button(String(localized: "itemEditor.value.loadCurrent", defaultValue: "Edit Current Value")) {
                    viewModel.loadCurrentValue()
                }
                .fxButtonStyle(.outline)
            }
            if let warning = viewModel.credentialWarning {
                CredentialWarningView(warning: warning) {
                    viewModel.resolveCredentialWarning()
                }
            }
        }
    }

    // MARK: - Fill (§7.1, §7.8)

    private var fillField: some View {
        ItemFillChoiceField(matchesGitHub: $viewModel.fillMatchesGitHub)
    }

    // MARK: - Push on Next Sync (v0.1.2)

    private var pushField: some View {
        ConfigSheetField(Self.onGitHubLabel) {
            if viewModel.isPushAlreadyRequested {
                ConfigEditorNoteView(note: .info(String(
                    localized: "itemEditor.push.alreadyRequested",
                    defaultValue: "The next Sync pushes this secret to GitHub. Revert it in the table to cancel."
                )))
            } else {
                FXCheckboxRow(
                    title: String(localized: "itemEditor.push.toggle", defaultValue: "Push on Next Sync"),
                    isOn: $viewModel.pushOnNextSync
                )
                .disabled(!viewModel.canEdit)
                ConfigEditorNoteView(note: .info(String(
                    localized: "itemEditor.push.note",
                    defaultValue: "Sends the value in FX Vault to GitHub on the next Sync even if it did not change, so GitHub matches FX Vault."
                )))
            }
        }
    }

    // MARK: - Linked copies (v0.4.1)

    private var linkedField: some View {
        ConfigSheetField(String(localized: "itemEditor.linked.header", defaultValue: "Linked copies")) {
            LinkedUpdateList(copies: viewModel.linkedCopies, itemName: viewModel.item?.name ?? viewModel.name, canEdit: viewModel.canEdit) { copy in
                Binding(
                    get: { viewModel.linkedSelection.contains(copy.itemID) && copy.isEditable },
                    set: { viewModel.setLinkedCopy(copy.itemID, included: $0) }
                )
            }
            ConfigEditorNoteView(note: .info(String(
                localized: "itemEditor.linked.note",
                defaultValue: "Checked copies get the new value too, as changes for the next Sync. Copies that still had the current value are checked."
            )))
        }
    }

    // MARK: - Convert / Move (D11)

    @ViewBuilder private var moveFields: some View {
        ConfigSheetField(Self.nameLabel) {
            ItemEditorReadOnlyName(name: viewModel.item?.name ?? "")
        }
        ConfigSheetField(String(localized: "itemEditor.move.kind", defaultValue: "Kind")) {
            SegmentedPill(
                selection: $viewModel.targetKind,
                segments: ConfigKind.allCases.map {
                    .init(value: $0, title: $0.editorTitle, isEnabled: viewModel.canMove(to: $0))
                },
                accessibilityLabel: String(localized: "itemEditor.move.kind", defaultValue: "Kind")
            )
        }
        ConfigSheetField(String(localized: "itemEditor.move.scope", defaultValue: "Scope")) {
            Picker(String(localized: "itemEditor.move.scope", defaultValue: "Scope"), selection: $viewModel.targetScope) {
                ForEach(viewModel.scopeOptions) { option in
                    Text(option.title)
                        .tag(option.scope)
                        .selectionDisabled(!option.isEditable)
                }
            }
            .labelsHidden()
            .fixedSize()
            ForEach(viewModel.moveNotes, id: \.self) { note in
                ConfigEditorNoteView(note: note)
            }
        }
    }
}

#Preview {
    if let dependencies = try? FeatureDependencies.preview() {
        ItemEditorScreen(
            context: ItemEditorContext(repositoryID: RepoID(), scope: .repository, mode: .add(.secret)),
            dependencies: dependencies
        )
    }
}
