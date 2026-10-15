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
    @FocusState private var isNameFocused: Bool

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
        }
    }

    private static var nameLabel: String {
        String(localized: "itemEditor.name", defaultValue: "Name")
    }

    private static var onGitHubLabel: String {
        String(localized: "itemEditor.fill.header", defaultValue: "On GitHub")
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
                TextField(
                    Self.nameLabel,
                    text: $viewModel.name,
                    prompt: Text(verbatim: "API_TOKEN").foregroundStyle(Theme.Colors.subtleText)
                )
                .focused($isNameFocused)
                .autocorrectionDisabled()
                .labelsHidden()
                .fxInputField(
                    .rounded,
                    isFocused: isNameFocused,
                    isInvalid: viewModel.nameNote?.isError ?? false,
                    isMonospaced: true
                )
                .disabled(!viewModel.canEdit)
                if let note = viewModel.nameNote {
                    ConfigEditorNoteView(note: note)
                }
                if let suggestion = viewModel.suggestedName {
                    HStack(spacing: Theme.Spacing.small) {
                        Text(String(localized: "itemEditor.name.suggestion", defaultValue: "Suggested: \(suggestion)"))
                            .fxTextStyle(.monoMeta)
                            .foregroundStyle(Theme.Colors.mutedText)
                            .textSelection(.enabled)
                        Spacer()
                        Button(String(localized: "itemEditor.name.useSuggestion", defaultValue: "Use Suggestion")) {
                            viewModel.applySuggestedName()
                        }
                        .fxButtonStyle(.outline)
                    }
                }
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
        ConfigSheetField(Self.onGitHubLabel) {
            FXCheckboxRow(
                title: String(localized: "itemEditor.fill.matchesGitHub", defaultValue: "Already matches GitHub (don't push)"),
                isOn: $viewModel.fillMatchesGitHub
            )
            ConfigEditorNoteView(note: .info(viewModel.fillMatchesGitHub
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

/// A name that cannot change here: mono in a quiet rounded frame, selectable.
private struct ItemEditorReadOnlyName: View {
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
private struct CredentialWarningView: View {
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

#Preview {
    if let dependencies = try? FeatureDependencies.preview() {
        ItemEditorScreen(
            context: ItemEditorContext(repositoryID: RepoID(), scope: .repository, mode: .add(.secret)),
            dependencies: dependencies
        )
    }
}
