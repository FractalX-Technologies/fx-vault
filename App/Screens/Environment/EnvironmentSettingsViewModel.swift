import Foundation
import Observation
import VaultCore
import VaultData

/// EnvironmentSettingsScreen (§10 Sheets, M4): the environment's name (renamed through
/// `RenameEnvironmentScreen`), its sync state, rules set on GitHub, and the `BranchPolicyEditor`
/// saved with `ConfigRepository.updateBranchPolicy`, plus the paid-plan note (§2).
@Observable
final class EnvironmentSettingsViewModel {
    let context: EnvironmentContext
    private(set) var directory: EnvironmentDirectoryModel?
    private(set) var environment: EnvironmentModel?
    private(set) var loadError: ErrorPresentationModel?
    var policy = BranchPolicyFormModel()
    var alert: ErrorPresentationModel?
    private(set) var isSaving = false

    /// The policy as stored when the sheet opened.
    @ObservationIgnored private var originalPolicy: BranchPolicyDraftModel = .all
    @ObservationIgnored private let dependencies: FeatureDependencies

    init(context: EnvironmentContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
        load()
    }

    func load() {
        do {
            let directory = try EnvironmentDirectoryModel.load(repositoryID: context.repositoryID, config: dependencies.config)
            guard let environment = directory.environment(context.environmentID) else {
                throw ConfigRepositoryError.environmentNotFound
            }
            guard !environment.isDeleted else { throw ConfigRepositoryError.environmentDeleted }
            self.directory = directory
            self.environment = environment
            originalPolicy = BranchPolicyDraftModel(environment.branchPolicy)
            policy = BranchPolicyFormModel(originalPolicy)
            loadError = nil
        } catch {
            loadError = error.presentation
        }
    }

    var title: String {
        String(localized: "environment.settings.title.named", defaultValue: "\(environment?.name ?? "") Settings")
    }

    var subtitle: String? {
        directory?.repository.fullName
    }

    var readOnlyReason: RepoCapabilityModel.ReadOnlyReason? {
        directory?.readOnlyReason
    }

    var canEdit: Bool {
        environment != nil && readOnlyReason == nil
    }

    var hasChanges: Bool {
        policy.draft != originalPolicy
    }

    var canSave: Bool {
        canEdit && !isSaving && hasChanges && policy.isReadyToSave
    }

    var showsPlanNote: Bool {
        directory?.showsPlanNote ?? false
    }

    var isPlanGated: Bool {
        directory?.repository.isEnvPlanGated ?? false
    }

    /// Where the environment stands on GitHub.
    var syncNote: ConfigEditorNoteModel? {
        guard let environment else { return nil }
        guard let syncedName = environment.syncedName else {
            return .info(String(
                localized: "environment.settings.notSynced",
                defaultValue: "Not on GitHub yet. The next Sync creates it with this policy."
            ))
        }
        if environment.hasPendingRename {
            return .info(String(
                localized: "environment.settings.pendingRename",
                defaultValue: "On GitHub as \(syncedName). The next Sync recreates it as \(environment.name)."
            ))
        }
        if environment.hasPendingPolicyChange || hasChanges {
            return .info(String(
                localized: "environment.settings.pendingPolicy",
                defaultValue: "On GitHub as \(syncedName). The next Sync applies this policy."
            ))
        }
        return .success(String(localized: "environment.settings.synced", defaultValue: "On GitHub as \(syncedName)."))
    }

    /// Reviewers, wait timers and custom rules set on GitHub, which FX Vault keeps as they are.
    var foreignRulesNote: ConfigEditorNoteModel? {
        guard environment?.foreignRulesJSON != nil else { return nil }
        return .info(String(
            localized: "environment.settings.foreignRules",
            defaultValue: "This environment also has protection rules set on GitHub (reviewers, wait timers or custom rules). FX Vault keeps them unchanged."
        ))
    }

    /// Opens `RenameEnvironmentScreen` in place of this sheet.
    func rename() {
        guard canEdit else { return }
        dependencies.actions.present(.renameEnvironment(context))
    }

    /// Saves the policy. Returns true when the sheet can close.
    func save() -> Bool {
        guard canSave else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            try dependencies.config.updateBranchPolicy(context.environmentID, to: policy.draft)
            return true
        } catch {
            alert = error.presentation
            return false
        }
    }
}
