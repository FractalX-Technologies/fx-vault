import SwiftUI
import VaultCore
import VaultData

/// A destination's Settings… (v0.8.0): its stage and, for Supabase and Vercel, which connection
/// it uses. The target itself never changes (add another destination instead).
@Observable
final class DestinationSettingsViewModel {
    let context: DestinationSettingsContext
    private(set) var destination: DestinationModel?
    var stage = ""
    private(set) var connections: [ConnectionModel] = []
    var connectionID: ConnectionID?
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let dependencies: FeatureDependencies

    init(context: DestinationSettingsContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
        destination = try? dependencies.destinations.destination(context.destinationID)
        stage = destination?.stage ?? ""
        connectionID = destination?.connectionID
        connections = ((try? dependencies.destinations.connections()) ?? []).filter { $0.provider == destination?.provider }
    }

    var stageProblem: String? {
        let trimmed = stage.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return EnvironmentNameValidator.violation(in: trimmed)?.localizedMessage
    }

    var usesConnection: Bool {
        destination?.provider.usesConnection == true
    }

    var canSave: Bool {
        destination != nil && stageProblem == nil && (!usesConnection || connectionID != nil)
    }

    /// Saves; returns true when the sheet can close.
    func save() -> Bool {
        guard canSave else { return false }
        do {
            let trimmed = stage.trimmingCharacters(in: .whitespaces)
            try dependencies.destinations.updateDestination(context.destinationID, stage: trimmed.isEmpty ? nil : trimmed, connectionID: connectionID)
            return true
        } catch {
            alert = error.presentation
            return false
        }
    }
}

struct DestinationSettingsScreen: View {
    @State private var viewModel: DestinationSettingsViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isStageFocused: Bool

    init(context: DestinationSettingsContext, dependencies: FeatureDependencies) {
        _viewModel = State(initialValue: DestinationSettingsViewModel(context: context, dependencies: dependencies))
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ConfigEditorSheet(
            eyebrow: DestinationCopy.eyebrow,
            title: viewModel.destination?.copyTargetTitle ?? "",
            subtitle: viewModel.destination?.targetDescription,
            primaryTitle: String(localized: "common.save", defaultValue: "Save"),
            isPrimaryEnabled: viewModel.canSave,
            isWorking: false,
            onCancel: { dismiss() },
            onPrimary: {
                if viewModel.save() { dismiss() }
            }
        ) {
            ConfigSheetField(DestinationCopy.stageLabel) {
                TextField(DestinationCopy.stageLabel, text: $viewModel.stage, prompt: Text(verbatim: "production"))
                    .focused($isStageFocused)
                    .autocorrectionDisabled()
                    .labelsHidden()
                    .fxInputField(.rounded, isFocused: isStageFocused, isInvalid: viewModel.stageProblem != nil)
                Text(viewModel.stageProblem ?? AddDestinationCopy.stageNote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(viewModel.stageProblem == nil ? Theme.Colors.mutedText : Theme.Colors.danger)
            }
            if viewModel.usesConnection {
                ConfigSheetField(AddDestinationCopy.connection) {
                    Picker(AddDestinationCopy.connection, selection: $viewModel.connectionID) {
                        Text(DestinationSettingsCopy.noConnection).tag(ConnectionID?.none)
                        ForEach(viewModel.connections) { connection in
                            Text(verbatim: [connection.label, connection.accountHint].compactMap { $0 }.joined(separator: " · "))
                                .tag(ConnectionID?.some(connection.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Text(DestinationSettingsCopy.connectionNote)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .errorAlert($viewModel.alert)
    }
}

enum DestinationSettingsCopy {
    static var noConnection: String {
        String(localized: "destinationSettings.noConnection", defaultValue: "Choose a connection")
    }

    static var connectionNote: String {
        String(
            localized: "destinationSettings.connection.note",
            defaultValue: "Add, check or replace tokens in Settings › Destinations."
        )
    }
}
