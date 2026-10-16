import DestinationKit
import SwiftUI
import VaultCore
import VaultData

/// "+ Add Destination" (v0.8.0): provider, stage, target and connection, then the import result.
struct AddDestinationScreen: View {
    @State private var viewModel: AddDestinationViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: AddDestinationContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: AddDestinationViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        Group {
            switch viewModel.phase {
            case .form, .working:
                ConfigEditorSheet(
                    eyebrow: DestinationCopy.runtimeSection,
                    title: viewModel.title,
                    subtitle: AddDestinationCopy.subtitle,
                    primaryTitle: AddDestinationCopy.add,
                    isPrimaryEnabled: viewModel.canAdd,
                    isWorking: viewModel.phase == .working,
                    width: Theme.Layout.destinationSheetWidth,
                    onCancel: { dismiss() },
                    onPrimary: { viewModel.add() }
                ) {
                    AddDestinationForm(viewModel: viewModel)
                }
            case .done(let added):
                AddDestinationResultView(added: added) {
                    viewModel.openDestination()
                    dismiss()
                }
            }
        }
        .errorAlert($viewModel.alert)
    }
}

private struct AddDestinationForm: View {
    @Bindable var viewModel: AddDestinationViewModel
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case stage, vault, tenant, project, tokenLabel, token
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            ConfigSheetField(AddDestinationCopy.provider) {
                SegmentedPill(
                    selection: $viewModel.provider,
                    segments: DestinationProvider.allCases.map { .init(value: $0, title: $0.title) },
                    accessibilityLabel: AddDestinationCopy.provider
                )
                .fixedSize()
                Text(AddDestinationCopy.providerNote(viewModel.provider))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ConfigSheetField(DestinationCopy.stageLabel) {
                HStack(spacing: Theme.Spacing.small) {
                    TextField(DestinationCopy.stageLabel, text: $viewModel.stage, prompt: Text(verbatim: "production"))
                        .focused($focused, equals: .stage)
                        .autocorrectionDisabled()
                        .labelsHidden()
                        .fxInputField(.rounded, isFocused: focused == .stage, isInvalid: viewModel.stageProblem != nil)
                    if !viewModel.stageSuggestions.isEmpty {
                        Menu(AddDestinationCopy.stages) {
                            ForEach(viewModel.stageSuggestions, id: \.self) { stage in
                                Button(stage) { viewModel.stage = stage }
                            }
                        }
                        .menuStyle(.button)
                        .fxButtonStyle(.outline)
                        .fixedSize()
                    }
                }
                Text(viewModel.stageProblem ?? AddDestinationCopy.stageNote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(viewModel.stageProblem == nil ? Theme.Colors.mutedText : Theme.Colors.danger)
            }
            switch viewModel.provider {
            case .azureKeyVault:
                keyVaultFields
            case .supabase, .vercel:
                connectionFields
                if case .existing = viewModel.connectionChoice {
                    if viewModel.provider == .supabase {
                        supabaseFields
                    } else {
                        vercelFields
                    }
                }
            }
            if let problem = viewModel.targetProblem {
                InlineErrorView(error: ErrorPresentationModel(title: AddDestinationCopy.title, message: problem))
            }
        }
    }

    @ViewBuilder
    private var keyVaultFields: some View {
        ConfigSheetField(AddDestinationCopy.vaultName) {
            TextField(AddDestinationCopy.vaultName, text: $viewModel.vaultName, prompt: Text(verbatim: "kv-myapp-prod"))
                .focused($focused, equals: .vault)
                .autocorrectionDisabled()
                .labelsHidden()
                .fxInputField(.rounded, isFocused: focused == .vault, isMonospaced: true)
        }
        ConfigSheetField(AddDestinationCopy.tenant) {
            TextField(AddDestinationCopy.tenant, text: $viewModel.tenantID, prompt: Text(AddDestinationCopy.tenantPrompt))
                .focused($focused, equals: .tenant)
                .autocorrectionDisabled()
                .labelsHidden()
                .fxInputField(.rounded, isFocused: focused == .tenant, isMonospaced: true)
            Text(AddDestinationCopy.azNote)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var connectionFields: some View {
        ConfigSheetField(AddDestinationCopy.connection) {
            Picker(AddDestinationCopy.connection, selection: $viewModel.connectionChoice) {
                ForEach(viewModel.availableConnections) { connection in
                    Text(verbatim: [connection.label, connection.accountHint].compactMap { $0 }.joined(separator: " · "))
                        .tag(AddDestinationViewModel.ConnectionChoice.existing(connection.id))
                }
                Text(AddDestinationCopy.newToken).tag(AddDestinationViewModel.ConnectionChoice.newToken)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            if viewModel.connectionChoice == .newToken {
                TextField(AddDestinationCopy.tokenLabel, text: $viewModel.newTokenLabel, prompt: Text(AddDestinationCopy.tokenLabelPrompt(viewModel.provider)))
                    .focused($focused, equals: .tokenLabel)
                    .labelsHidden()
                    .fxInputField(.rounded, isFocused: focused == .tokenLabel)
                SecureField(AddDestinationCopy.token, text: $viewModel.newToken, prompt: Text(AddDestinationCopy.token))
                    .focused($focused, equals: .token)
                    .labelsHidden()
                    .fxInputField(.rounded, isFocused: focused == .token, isMonospaced: true)
                HStack(spacing: Theme.Spacing.small) {
                    Text(AddDestinationCopy.tokenNote(viewModel.provider))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(AddDestinationCopy.checkToken) { viewModel.saveToken() }
                        .fxButtonStyle(.outline)
                        .disabled(!viewModel.canSaveToken)
                        .fixedSize()
                }
            }
            if viewModel.isLoadingLists {
                ProgressView()
                    .controlSize(.small)
            }
            if let error = viewModel.listError {
                Text(error)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var supabaseFields: some View {
        ConfigSheetField(AddDestinationCopy.project) {
            if viewModel.supabaseProjects.isEmpty {
                TextField(AddDestinationCopy.projectRef, text: $viewModel.projectRef, prompt: Text(verbatim: "abcdefghijklmnopqrst"))
                    .focused($focused, equals: .project)
                    .autocorrectionDisabled()
                    .labelsHidden()
                    .fxInputField(.rounded, isFocused: focused == .project, isMonospaced: true)
            } else {
                Picker(AddDestinationCopy.project, selection: $viewModel.projectRef) {
                    ForEach(viewModel.supabaseProjects) { project in
                        Text(verbatim: "\(project.name) · \(project.ref)").tag(project.ref)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var vercelFields: some View {
        ConfigSheetField(AddDestinationCopy.team) {
            Picker(AddDestinationCopy.team, selection: $viewModel.vercelTeamID) {
                Text(viewModel.vercelUser.map { AddDestinationCopy.personal($0.username) } ?? AddDestinationCopy.personal(nil))
                    .tag(String?.none)
                ForEach(viewModel.vercelTeams) { team in
                    Text(verbatim: team.name ?? team.slug).tag(String?.some(team.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .onChange(of: viewModel.vercelTeamID) { viewModel.loadVercelProjects() }
        }
        ConfigSheetField(AddDestinationCopy.project) {
            Picker(AddDestinationCopy.project, selection: $viewModel.vercelProjectID) {
                Text(AddDestinationCopy.chooseProject).tag(String?.none)
                ForEach(viewModel.vercelProjects) { project in
                    Text(verbatim: project.name).tag(String?.some(project.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        ConfigSheetField(AddDestinationCopy.environment) {
            SegmentedPill(
                selection: $viewModel.vercelEnvironment,
                segments: VercelEnvironment.allCases.map { .init(value: $0, title: $0.title) },
                accessibilityLabel: AddDestinationCopy.environment
            )
            .fixedSize()
        }
    }
}

/// What the import found, with Open Destination.
private struct AddDestinationResultView: View {
    let added: DestinationAddedModel
    let open: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            SheetHeader(label: DestinationCopy.runtimeSection, title: AddDestinationCopy.addedTitle, subtitle: nil)
            if let error = added.importError {
                Banner(.warning, message: AddDestinationCopy.importFailed(error), systemImage: "exclamationmark.triangle")
            } else if let result = added.result {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Text(AddDestinationCopy.imported(result.imported.count))
                        .fxTextStyle(.body)
                    if !result.withoutValue.isEmpty {
                        Text(AddDestinationCopy.withoutValue(result.withoutValue.count))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !result.unusable.isEmpty {
                        Text(AddDestinationCopy.unusable(result.unusable.map { "\($0.remoteName) (\($0.reason.localizedMessage))" }))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: Theme.Spacing.medium) {
                Spacer(minLength: 0)
                Button(String(localized: "common.done", defaultValue: "Done")) { dismiss() }
                    .fxButtonStyle(.secondary, size: .large)
                Button(AddDestinationCopy.open, action: open)
                    .fxButtonStyle(.primary, size: .large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xxLarge)
        .frame(width: Theme.Layout.destinationSheetWidth)
    }
}

/// The text of Add Destination (v0.8.0).
enum AddDestinationCopy {
    static var title: String { String(localized: "addDestination.title", defaultValue: "Add Destination") }
    static var subtitle: String {
        String(
            localized: "addDestination.subtitle",
            defaultValue: "A place outside GitHub this repository's code reads at runtime. Nothing is changed there until you Sync."
        )
    }
    static var add: String { String(localized: "addDestination.add", defaultValue: "Add and Import") }
    static var provider: String { String(localized: "addDestination.provider", defaultValue: "Provider") }
    static func providerNote(_ provider: DestinationProvider) -> String {
        switch provider {
        case .azureKeyVault:
            String(localized: "addDestination.note.keyVault", defaultValue: "Secrets only. FX Vault uses your az login; the token never leaves memory.")
        case .supabase:
            String(localized: "addDestination.note.supabase", defaultValue: "Edge Function secrets of one project, through a Supabase access token.")
        case .vercel:
            String(localized: "addDestination.note.vercel", defaultValue: "One environment of one project, through a Vercel access token.")
        }
    }
    static var stages: String { String(localized: "addDestination.stages", defaultValue: "Stages") }
    static var stageNote: String {
        String(localized: "addDestination.stage.note", defaultValue: "The Overview lines it up with the GitHub environment of the same name.")
    }
    static var vaultName: String { String(localized: "addDestination.vault", defaultValue: "Vault name") }
    static var tenant: String { String(localized: "addDestination.tenant", defaultValue: "Tenant (optional)") }
    static var tenantPrompt: String { String(localized: "addDestination.tenant.prompt", defaultValue: "Default tenant of az") }
    static var azNote: String {
        String(
            localized: "addDestination.az.note",
            defaultValue: "Needs the Azure CLI signed in (az login) with permission to read and set secrets in the vault."
        )
    }
    static var connection: String { String(localized: "addDestination.connection", defaultValue: "Connection") }
    static var newToken: String { String(localized: "addDestination.newToken", defaultValue: "New Token…") }
    static var tokenLabel: String { String(localized: "addDestination.tokenLabel", defaultValue: "Name") }
    static func tokenLabelPrompt(_ provider: DestinationProvider) -> String {
        String(localized: "addDestination.tokenLabel.prompt", defaultValue: "\(provider.title) token")
    }
    static var token: String { String(localized: "addDestination.token", defaultValue: "Access token") }
    static func tokenNote(_ provider: DestinationProvider) -> String {
        switch provider {
        case .supabase:
            String(localized: "addDestination.token.supabase", defaultValue: "Create one at supabase.com › Account › Access Tokens. FX Vault keeps it encrypted in the vault.")
        default:
            String(localized: "addDestination.token.vercel", defaultValue: "Create one at vercel.com › Account Settings › Tokens. FX Vault keeps it encrypted in the vault.")
        }
    }
    static var checkToken: String { String(localized: "addDestination.checkToken", defaultValue: "Check and Save") }
    static var project: String { String(localized: "addDestination.project", defaultValue: "Project") }
    static var projectRef: String { String(localized: "addDestination.projectRef", defaultValue: "Project reference") }
    static var team: String { String(localized: "addDestination.team", defaultValue: "Team") }
    static func personal(_ username: String?) -> String {
        username.map { String(localized: "addDestination.personal.named", defaultValue: "Personal · \($0)") }
            ?? String(localized: "addDestination.personal", defaultValue: "Personal account")
    }
    static var chooseProject: String { String(localized: "addDestination.chooseProject", defaultValue: "Choose a project") }
    static var environment: String { String(localized: "addDestination.environment", defaultValue: "Environment") }
    static var addedTitle: String { String(localized: "addDestination.added", defaultValue: "Destination added") }
    static func imported(_ count: Int) -> String {
        count == 1
            ? String(localized: "addDestination.imported.one", defaultValue: "1 item imported from the destination.")
            : String(localized: "addDestination.imported", defaultValue: "\(count) items imported from the destination.")
    }
    static func withoutValue(_ count: Int) -> String {
        count == 1
            ? String(
                localized: "addDestination.withoutValue.one",
                defaultValue: "1 of them has no value in FX Vault: the provider never returns it. Fill it to copy or rotate it."
            )
            : String(
                localized: "addDestination.withoutValue",
                defaultValue: "\(count) of them have no value in FX Vault: the provider never returns it. Fill them to copy or rotate them."
            )
    }
    static func unusable(_ names: [String]) -> String {
        String(localized: "addDestination.unusable", defaultValue: "Left as they are: \(names.joined(separator: ", ")).")
    }
    static func importFailed(_ message: String) -> String {
        String(localized: "addDestination.importFailed", defaultValue: "The destination was added, but its items could not be listed: \(message) Use Refresh once that is fixed.")
    }
    static var open: String { String(localized: "addDestination.open", defaultValue: "Open Destination") }
}
