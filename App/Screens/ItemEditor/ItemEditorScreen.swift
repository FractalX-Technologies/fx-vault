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

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigEditorSheet(
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
                Section {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }
            case .unavailable(let error):
                Section {
                    ConfigEditorNoteView(note: .error(error.message))
                }
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

/// The form rows of a loaded editor, by mode.
private struct ItemEditorForm: View {
    @Bindable var viewModel: ItemEditorViewModel

    var body: some View {
        if let reason = viewModel.readOnlyReason {
            Section {
                ConfigEditorNoteView(note: .warning(reason.localizedExplanation))
            }
        }
        if viewModel.isMoving {
            moveSection
        } else {
            identitySection
            valueSection
            if viewModel.offersFillChoice {
                fillSection
            }
            if viewModel.offersPushOnNextSync || viewModel.isPushAlreadyRequested {
                pushSection
            }
        }
    }

    // MARK: - Kind and name

    @ViewBuilder private var identitySection: some View {
        Section {
            Picker(String(localized: "itemEditor.kind", defaultValue: "Kind"), selection: $viewModel.kind) {
                ForEach(ConfigKind.allCases, id: \.self) { kind in
                    Text(kind.editorTitle).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!viewModel.isKindEditable || !viewModel.canEdit)
            if let note = viewModel.kindLockNote {
                ConfigEditorNoteView(note: note)
            }

            if viewModel.isNameEditable {
                TextField(
                    String(localized: "itemEditor.name", defaultValue: "Name"),
                    text: $viewModel.name,
                    prompt: Text(verbatim: "API_TOKEN")
                )
                .font(Theme.Typography.monospaced)
                .autocorrectionDisabled()
                .disabled(!viewModel.canEdit)
                if let note = viewModel.nameNote {
                    ConfigEditorNoteView(note: note)
                }
                if let suggestion = viewModel.suggestedName {
                    HStack {
                        Text(String(localized: "itemEditor.name.suggestion", defaultValue: "Suggested: \(suggestion)"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Spacer()
                        Button(String(localized: "itemEditor.name.useSuggestion", defaultValue: "Use Suggestion")) {
                            viewModel.applySuggestedName()
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                LabeledContent(String(localized: "itemEditor.name", defaultValue: "Name")) {
                    Text(viewModel.item?.name ?? "")
                        .font(Theme.Typography.monospaced)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Value

    @ViewBuilder private var valueSection: some View {
        Section {
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
                .controlSize(.small)
            }
            if let warning = viewModel.credentialWarning {
                CredentialWarningView(warning: warning) {
                    viewModel.resolveCredentialWarning()
                }
            }
        } header: {
            Text(String(localized: "itemEditor.value", defaultValue: "Value"))
        }
    }

    // MARK: - Fill (§7.1, §7.8)

    private var fillSection: some View {
        Section {
            Toggle(
                String(localized: "itemEditor.fill.matchesGitHub", defaultValue: "Already matches GitHub (don't push)"),
                isOn: $viewModel.fillMatchesGitHub
            )
            .toggleStyle(.checkbox)
            ConfigEditorNoteView(note: .info(viewModel.fillMatchesGitHub
                ? String(
                    localized: "itemEditor.fill.matchesGitHub.note",
                    defaultValue: "Only when you are sure GitHub has exactly this value. Nothing is pushed."
                )
                : String(
                    localized: "itemEditor.fill.pushes.note",
                    defaultValue: "The next Sync replaces the secret on GitHub with this value, so GitHub matches FX Vault."
                )))
        } header: {
            Text(String(localized: "itemEditor.fill.header", defaultValue: "On GitHub"))
        }
    }

    // MARK: - Push on Next Sync (v0.1.2)

    @ViewBuilder private var pushSection: some View {
        Section {
            if viewModel.isPushAlreadyRequested {
                ConfigEditorNoteView(note: .info(String(
                    localized: "itemEditor.push.alreadyRequested",
                    defaultValue: "The next Sync pushes this secret to GitHub. Revert it in the table to cancel."
                )))
            } else {
                Toggle(
                    String(localized: "itemEditor.push.toggle", defaultValue: "Push on Next Sync"),
                    isOn: $viewModel.pushOnNextSync
                )
                .toggleStyle(.checkbox)
                .disabled(!viewModel.canEdit)
                ConfigEditorNoteView(note: .info(String(
                    localized: "itemEditor.push.note",
                    defaultValue: "Sends the value in FX Vault to GitHub on the next Sync even if it did not change, so GitHub matches FX Vault."
                )))
            }
        } header: {
            Text(String(localized: "itemEditor.fill.header", defaultValue: "On GitHub"))
        }
    }

    // MARK: - Convert / Move (D11)

    @ViewBuilder private var moveSection: some View {
        Section {
            LabeledContent(String(localized: "itemEditor.name", defaultValue: "Name")) {
                Text(viewModel.item?.name ?? "")
                    .font(Theme.Typography.monospaced)
            }
            Picker(String(localized: "itemEditor.move.kind", defaultValue: "Kind"), selection: $viewModel.targetKind) {
                ForEach(ConfigKind.allCases, id: \.self) { kind in
                    Text(kind.editorTitle)
                        .tag(kind)
                        .selectionDisabled(!viewModel.canMove(to: kind))
                }
            }
            .pickerStyle(.segmented)
            Picker(String(localized: "itemEditor.move.scope", defaultValue: "Scope"), selection: $viewModel.targetScope) {
                ForEach(viewModel.scopeOptions) { option in
                    Text(option.title)
                        .tag(option.scope)
                        .selectionDisabled(!option.isEditable)
                }
            }
            ForEach(viewModel.moveNotes, id: \.self) { note in
                ConfigEditorNoteView(note: note)
            }
        }
    }
}

/// The credential-looking-variable warning (§5.13) with its "make it a secret" action.
private struct CredentialWarningView: View {
    let warning: CredentialWarningModel
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            ConfigEditorNoteView(note: .warning(String(
                localized: "itemEditor.credential.title",
                defaultValue: "This looks like a credential. Variable values are stored in plain text on GitHub; keep it as a secret instead."
            )))
            ForEach(warning.reasons, id: \.self) { reason in
                Text(reason)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            if let action = warning.action {
                Button(action == .switchToSecret
                    ? String(localized: "itemEditor.credential.makeSecret", defaultValue: "Make It a Secret")
                    : String(localized: "itemEditor.credential.convert", defaultValue: "Convert to Secret…")) {
                        onAction()
                    }
                    .controlSize(.small)
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
