import SwiftUI
import VaultCore
import VaultData

/// "+ Add Destination" (v0.8.0): stage and Key Vault, then the import result.
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
        case stage, vault, tenant
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
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
            keyVaultFields
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
            Text(AddDestinationCopy.keyVaultNote)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.mutedText)
                .fixedSize(horizontal: false, vertical: true)
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
    static var keyVaultNote: String {
        String(localized: "addDestination.note.keyVault", defaultValue: "Secrets only. FX Vault uses your az login; the token never leaves memory.")
    }
    static var stages: String { String(localized: "addDestination.stages", defaultValue: "Stages") }
    static var stageNote: String {
        String(localized: "addDestination.stage.note", defaultValue: "Use the name of the GitHub environment it serves, for example production.")
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
