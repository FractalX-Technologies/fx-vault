import SwiftUI
import VaultCore
import VaultData

/// Preferences › Destinations (v0.8.0): the Azure CLI sign-in, then the Supabase and Vercel tokens
/// with Rename…, Replace Token… and Remove…, and Add Connection….
struct DestinationsSettingsScreen: View {
    let viewModel: DestinationsSettingsViewModel

    var body: some View {
        if viewModel.isUnlocked {
            DestinationsSettingsContent(viewModel: viewModel)
        } else {
            VaultSettingsLockedView()
        }
    }
}

private struct DestinationsSettingsContent: View {
    @Bindable var viewModel: DestinationsSettingsViewModel

    var body: some View {
        PreferencesPage {
            PreferencesSection(
                String(localized: "settings.destinations.azure", defaultValue: "Azure Key Vault"),
                footnote: String(
                    localized: "settings.destinations.azure.footnote",
                    defaultValue: "FX Vault asks your Azure CLI sign-in for a short-lived Key Vault token when it syncs; the token stays in memory."
                )
            ) {
                PreferencesRow(
                    String(localized: "settings.destinations.azure.status", defaultValue: "Azure CLI"),
                    detail: azureDetail
                ) {
                    HStack(spacing: Theme.Spacing.small) {
                        if case .problem = viewModel.azureState {
                            Button(String(localized: "settings.destinations.copyLogin", defaultValue: "Copy az login")) {
                                viewModel.copyAzLogin()
                            }
                            .fxButtonStyle(.outline)
                        }
                        Button(String(localized: "settings.destinations.check", defaultValue: "Check")) {
                            viewModel.checkAzure()
                        }
                        .fxButtonStyle(.secondary)
                        .disabled(viewModel.azureState == .checking)
                    }
                }
            }
            PreferencesSection(
                String(localized: "settings.destinations.connections", defaultValue: "Supabase and Vercel"),
                footnote: String(
                    localized: "settings.destinations.connections.footnote",
                    defaultValue: "Personal access tokens, encrypted in the vault. Removing one keeps its destinations; choose another in their settings."
                )
            ) {
                if viewModel.connections.isEmpty {
                    PreferencesBlock {
                        Text(String(
                            localized: "settings.destinations.empty",
                            defaultValue: "No tokens yet. Add one here, or while adding a Supabase or Vercel destination."
                        ))
                        .fxTextStyle(.body)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(Array(viewModel.connections.enumerated()), id: \.element.id) { index, connection in
                    if index > 0 {
                        HairlineDivider()
                    }
                    PreferencesRow(connection.label, detail: detail(of: connection)) {
                        Menu {
                            Button(String(localized: "settings.destinations.rename", defaultValue: "Rename…")) {
                                viewModel.startRename(connection)
                            }
                            Button(String(localized: "settings.destinations.replace", defaultValue: "Replace Token…")) {
                                viewModel.replaceToken(of: connection)
                            }
                            Divider()
                            Button(String(localized: "settings.destinations.remove", defaultValue: "Remove…"), role: .destructive) {
                                viewModel.requestRemoval(connection)
                            }
                        } label: {
                            Label(String(localized: "main.detail.actions", defaultValue: "Actions"), systemImage: "ellipsis")
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fxIconButtonStyle()
                    }
                }
                HairlineDivider()
                PreferencesBlock {
                    Button(String(localized: "settings.destinations.add", defaultValue: "Add Connection…")) {
                        viewModel.addConnection()
                    }
                    .fxButtonStyle(.outline)
                }
            }
            if let notice = viewModel.notice {
                Text(notice)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
            }
        }
        .sheet(item: $viewModel.editor) { _ in
            ConnectionEditorSheet(viewModel: viewModel)
        }
        .alert(
            String(localized: "settings.destinations.rename.title", defaultValue: "Rename Connection"),
            isPresented: renameBinding
        ) {
            TextField(String(localized: "settings.destinations.rename.field", defaultValue: "Name"), text: $viewModel.renameText)
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) { viewModel.renaming = nil }
            Button(String(localized: "settings.destinations.rename.confirm", defaultValue: "Rename")) { viewModel.confirmRename() }
        }
        .confirmationDialog(
            String(localized: "settings.destinations.remove.title", defaultValue: "Remove this connection?"),
            isPresented: removalBinding,
            titleVisibility: .visible
        ) {
            Button(String(localized: "settings.destinations.remove.confirm", defaultValue: "Remove Connection"), role: .destructive) {
                viewModel.confirmRemoval()
            }
        } message: {
            Text(String(
                localized: "settings.destinations.remove.message",
                defaultValue: "The token is deleted from FX Vault. Its destinations stay and need another connection before the next Sync."
            ))
        }
        .errorAlert($viewModel.alert)
    }

    private var azureDetail: String {
        switch viewModel.azureState {
        case .unknown:
            String(localized: "settings.destinations.azure.unknown", defaultValue: "Not checked yet")
        case .checking:
            String(localized: "settings.destinations.azure.checking", defaultValue: "Checking…")
        case .signedIn:
            String(localized: "settings.destinations.azure.signedIn", defaultValue: "Signed in")
        case .problem(let message):
            message
        }
    }

    private func detail(of connection: ConnectionModel) -> String {
        var parts = [connection.provider.title]
        if let hint = connection.accountHint {
            // Supabase stores the project count as its hint, Vercel the username.
            switch (connection.provider, hint) {
            case (.supabase, "1"):
                parts.append(String(localized: "settings.destinations.projects.one", defaultValue: "1 project"))
            case (.supabase, _):
                parts.append(String(localized: "settings.destinations.projects", defaultValue: "\(hint) projects"))
            default:
                parts.append(hint)
            }
        }
        return parts.joined(separator: " · ")
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { viewModel.renaming != nil }, set: { if !$0 { viewModel.renaming = nil } })
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { viewModel.pendingRemoval != nil }, set: { if !$0 { viewModel.pendingRemoval = nil } })
    }
}

/// Add Connection… and Replace Token…: provider (when adding), name and token, Check and Save.
private struct ConnectionEditorSheet: View {
    @Bindable var viewModel: DestinationsSettingsViewModel
    @FocusState private var focused: Bool

    var body: some View {
        if let editor = viewModel.editor {
            ConfigEditorSheet(
                eyebrow: String(localized: "settings.destinations.editor.eyebrow", defaultValue: "Destinations"),
                title: editor.mode == .add
                    ? String(localized: "settings.destinations.editor.add", defaultValue: "Add Connection")
                    : String(localized: "settings.destinations.editor.replace", defaultValue: "Replace Token"),
                subtitle: AddDestinationCopy.tokenNote(editor.provider),
                primaryTitle: AddDestinationCopy.checkToken,
                isPrimaryEnabled: editor.canSave,
                isWorking: editor.isChecking,
                onCancel: { viewModel.cancelEditor() },
                onPrimary: { viewModel.saveEditor() }
            ) {
                if editor.mode == .add {
                    ConfigSheetField(AddDestinationCopy.provider) {
                        SegmentedPill(
                            selection: providerBinding,
                            segments: [DestinationProvider.vercel, .supabase].map { .init(value: $0, title: $0.title) },
                            accessibilityLabel: AddDestinationCopy.provider
                        )
                        .fixedSize()
                    }
                    ConfigSheetField(AddDestinationCopy.tokenLabel) {
                        TextField(AddDestinationCopy.tokenLabel, text: labelBinding, prompt: Text(AddDestinationCopy.tokenLabelPrompt(editor.provider)))
                            .labelsHidden()
                            .fxInputField(.rounded)
                    }
                }
                ConfigSheetField(AddDestinationCopy.token) {
                    SecureField(AddDestinationCopy.token, text: tokenBinding)
                        .focused($focused)
                        .labelsHidden()
                        .fxInputField(.rounded, isFocused: focused, isInvalid: editor.error != nil, isMonospaced: true)
                    if let error = editor.error {
                        Text(error)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .onAppear { focused = true }
        }
    }

    private var providerBinding: Binding<DestinationProvider> {
        Binding(get: { viewModel.editor?.provider ?? .vercel }, set: { viewModel.editor?.provider = $0 })
    }

    private var labelBinding: Binding<String> {
        Binding(get: { viewModel.editor?.label ?? "" }, set: { viewModel.editor?.label = $0 })
    }

    private var tokenBinding: Binding<String> {
        Binding(get: { viewModel.editor?.token ?? "" }, set: { viewModel.editor?.token = $0 })
    }
}
