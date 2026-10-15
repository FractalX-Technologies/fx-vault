import Foundation
import Observation
import VaultCore
import VaultData

/// "+ New Environment" (§10, M3/M4): a name with live fold-key availability and the deployment
/// branch policy, created locally with `ConfigRepository.createEnvironment`; the next Sync
/// creates it on GitHub. Re-creating a deleted environment's name restores it (§7.1).
@Observable
final class NewEnvironmentViewModel {
    let context: NewEnvironmentContext
    private(set) var directory: EnvironmentDirectoryModel?
    /// Why the sheet cannot work (the repository is gone), or nil.
    private(set) var loadError: ErrorPresentationModel?
    var name = ""
    var policy = BranchPolicyFormModel()
    var alert: ErrorPresentationModel?
    private(set) var isSaving = false
    /// The environment created by the last ``create()``.
    private(set) var createdID: EnvironmentID?

    @ObservationIgnored private let dependencies: FeatureDependencies

    init(context: NewEnvironmentContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
        load()
    }

    func load() {
        do {
            directory = try EnvironmentDirectoryModel.load(repositoryID: context.repositoryID, config: dependencies.config)
            loadError = nil
        } catch {
            loadError = error.presentation
        }
    }

    var subtitle: String? {
        directory.map { directory in
            String(
                localized: "environment.new.subtitle",
                defaultValue: "In \(directory.repository.fullName). The next Sync creates it on GitHub."
            )
        }
    }

    var readOnlyReason: RepoCapabilityModel.ReadOnlyReason? {
        directory?.readOnlyReason
    }

    var canEdit: Bool {
        directory != nil && readOnlyReason == nil
    }

    var nameStatus: EnvironmentNameStatusModel {
        directory?.nameStatus(of: name, for: .create) ?? .empty
    }

    var showsPlanNote: Bool {
        directory?.showsPlanNote ?? false
    }

    var isPlanGated: Bool {
        directory?.repository.isEnvPlanGated ?? false
    }

    var canCreate: Bool {
        canEdit && !isSaving && nameStatus.isAcceptable && policy.isReadyToSave
    }

    /// Creates the environment. Returns true when the sheet can close.
    func create() -> Bool {
        guard canCreate else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            createdID = try dependencies.config.createEnvironment(
                in: context.repositoryID,
                name: EnvironmentNameValidator.normalize(name),
                policy: policy.draft
            )
            return true
        } catch {
            alert = error.presentation
            return false
        }
    }
}
