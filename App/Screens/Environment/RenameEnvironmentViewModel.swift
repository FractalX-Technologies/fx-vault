import Foundation
import Observation
import VaultCore
import VaultData

/// RenameEnvironmentScreen (§7.6, D20, M4): a never-synced environment or a case-only change is
/// renamed locally; a synced environment with a new name is recreated on GitHub by the next
/// Sync (guided rename), which needs every secret's value, so the sheet blocks while any is
/// missing and offers "Enter Values".
@Observable
final class RenameEnvironmentViewModel {
    let context: EnvironmentContext
    private(set) var directory: EnvironmentDirectoryModel?
    private(set) var environment: EnvironmentModel?
    /// Live secrets of the environment whose value is not in the vault (§7.8).
    private(set) var valueMissingSecrets: [ConfigItemModel] = []
    private(set) var isLoaded = false
    private(set) var loadError: ErrorPresentationModel?
    var name = ""
    var alert: ErrorPresentationModel?
    private(set) var isSaving = false
    /// What the last ``rename()`` did.
    private(set) var result: EnvironmentRenameKind?

    @ObservationIgnored private let dependencies: FeatureDependencies

    init(context: EnvironmentContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
    }

    /// Reads the environment and its items. Call once when the sheet opens.
    func load() async {
        do {
            let directory = try EnvironmentDirectoryModel.load(repositoryID: context.repositoryID, config: dependencies.config)
            guard let environment = directory.environment(context.environmentID) else {
                throw ConfigRepositoryError.environmentNotFound
            }
            guard !environment.isDeleted else { throw ConfigRepositoryError.environmentDeleted }
            let items = try await dependencies.config.editorItems(
                repositoryID: context.repositoryID,
                scope: .environment(context.environmentID)
            )
            self.directory = directory
            self.environment = environment
            valueMissingSecrets = items
                .filter { $0.kind == .secret && !$0.isDeleted && !$0.hasValue }
                .sorted { $0.name < $1.name }
            name = environment.name
            loadError = nil
        } catch {
            loadError = error.presentation
        }
        isLoaded = true
    }

    var subtitle: String? {
        guard let environment, let directory else { return nil }
        return String(
            localized: "environment.rename.subtitle",
            defaultValue: "\(environment.name) in \(directory.repository.fullName)"
        )
    }

    var readOnlyReason: RepoCapabilityModel.ReadOnlyReason? {
        directory?.readOnlyReason
    }

    var canEdit: Bool {
        environment != nil && readOnlyReason == nil
    }

    var nameStatus: EnvironmentNameStatusModel {
        directory?.nameStatus(of: name, for: .rename(context.environmentID)) ?? .empty
    }

    /// What the rename will mean on GitHub (mirrors `ConfigRepository.renameEnvironment`).
    var predictedKind: EnvironmentRenameKind {
        guard let environment else { return .unchanged }
        let normalized = EnvironmentNameValidator.normalize(name)
        guard normalized != environment.name else { return .unchanged }
        guard let syncedName = environment.syncedName, let syncedKey = environment.syncedNameKey else {
            return .local
        }
        if EnvironmentNameValidator.foldKey(normalized) != syncedKey {
            return .recreateOnGitHub
        }
        return normalized == syncedName ? .local : .caseOnly
    }

    /// The guided recreate needs every secret value (§7.6 step 2).
    var isBlockedByMissingValues: Bool {
        predictedKind == .recreateOnGitHub && !valueMissingSecrets.isEmpty
    }

    var canRename: Bool {
        canEdit && !isSaving && nameStatus.isAcceptable && !isBlockedByMissingValues
    }

    /// The explanation for the predicted rename.
    var kindNote: ConfigEditorNoteModel? {
        guard let environment, nameStatus.isAcceptable else { return nil }
        switch predictedKind {
        case .unchanged:
            return nil
        case .local:
            return .info(environment.isSynced
                ? String(
                    localized: "environment.rename.backToSynced",
                    defaultValue: "This is the name GitHub has, so nothing changes on GitHub."
                )
                : String(
                    localized: "environment.rename.local",
                    defaultValue: "This environment is not on GitHub yet, so the rename stays local."
                ))
        case .caseOnly:
            return .info(String(
                localized: "environment.rename.caseOnly",
                defaultValue: "Only the letter case changes. GitHub compares environment names without case and keeps \(environment.syncedName ?? environment.name), so this rename stays local."
            ))
        case .recreateOnGitHub:
            return .warning(String(
                localized: "environment.rename.recreate",
                defaultValue: "GitHub cannot rename environments. The next Sync creates \(EnvironmentNameValidator.normalize(name)) with the same branch rules, secrets and variables, verifies it, then asks you to delete \(environment.syncedName ?? environment.name). Deployment history, reviewers, wait timers, custom rules and workflow environment: references do not carry over."
            ))
        }
    }

    /// Why the rename is blocked: the secrets whose values are missing (names only).
    var missingValuesNote: ConfigEditorNoteModel? {
        guard isBlockedByMissingValues else { return nil }
        let names = valueMissingSecrets.map(\.name).formatted(.list(type: .and))
        return .error(String(
            localized: "environment.rename.valuesMissing",
            defaultValue: "Recreating the environment pushes every secret, but FX Vault has no value for \(names). Enter their values first."
        ))
    }

    /// "Enter Values": opens the item editor in fill mode for the first value-missing secret.
    func enterValues() {
        guard let secret = valueMissingSecrets.first else { return }
        dependencies.actions.present(.itemEditor(ItemEditorContext(
            repositoryID: context.repositoryID,
            scope: .environment(context.environmentID),
            mode: .fill(secret.id)
        )))
    }

    /// Renames the environment. Returns true when the sheet can close.
    func rename() -> Bool {
        guard canRename else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            result = try dependencies.config.renameEnvironment(
                context.environmentID,
                to: EnvironmentNameValidator.normalize(name)
            )
            return true
        } catch {
            alert = error.presentation
            return false
        }
    }
}
