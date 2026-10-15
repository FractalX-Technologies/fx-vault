import Foundation
import Observation
import VaultCore
import VaultData

/// DuplicateEnvironmentScreen (§7.8, M5): copies an environment's branch policy and every
/// secret and variable into a new environment with `ConfigRepository.duplicateEnvironment`.
/// Values are re-encrypted for the new rows inside the repository; value-missing secrets stay
/// value-missing (Sync blocks them until they are filled). The sheet shows counts only.
@Observable
final class DuplicateEnvironmentViewModel {
    let context: EnvironmentContext
    private(set) var directory: EnvironmentDirectoryModel?
    private(set) var source: EnvironmentModel?
    private(set) var secretCount = 0
    private(set) var variableCount = 0
    private(set) var valueMissingCount = 0
    private(set) var isLoaded = false
    private(set) var loadError: ErrorPresentationModel?
    var name = ""
    var alert: ErrorPresentationModel?
    private(set) var isSaving = false
    /// The environment created by the last ``duplicate()``.
    private(set) var createdID: EnvironmentID?

    @ObservationIgnored private let dependencies: FeatureDependencies

    init(context: EnvironmentContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
    }

    /// Reads the source environment and counts its items. Call once when the sheet opens.
    func load() async {
        do {
            let directory = try EnvironmentDirectoryModel.load(repositoryID: context.repositoryID, config: dependencies.config)
            guard let source = directory.environment(context.environmentID) else {
                throw ConfigRepositoryError.environmentNotFound
            }
            guard !source.isDeleted else { throw ConfigRepositoryError.environmentDeleted }
            let items = try await dependencies.config.editorItems(
                repositoryID: context.repositoryID,
                scope: .environment(context.environmentID)
            )
            .filter { !$0.isDeleted }
            self.directory = directory
            self.source = source
            secretCount = items.filter { $0.kind == .secret }.count
            variableCount = items.filter { $0.kind == .variable }.count
            valueMissingCount = items.filter { $0.kind == .secret && !$0.hasValue }.count
            loadError = nil
        } catch {
            loadError = error.presentation
        }
        isLoaded = true
    }

    var subtitle: String? {
        guard let source, let directory else { return nil }
        return String(
            localized: "environment.duplicate.subtitle",
            defaultValue: "Copy \(source.name) in \(directory.repository.fullName)"
        )
    }

    var readOnlyReason: RepoCapabilityModel.ReadOnlyReason? {
        directory?.readOnlyReason
    }

    var canEdit: Bool {
        source != nil && readOnlyReason == nil
    }

    var nameStatus: EnvironmentNameStatusModel {
        directory?.nameStatus(of: name, for: .duplicate) ?? .empty
    }

    var canDuplicate: Bool {
        canEdit && !isSaving && nameStatus.isAcceptable
    }

    /// What is copied (names and counts only, never values).
    var summary: String? {
        guard let source else { return nil }
        return String(
            localized: "environment.duplicate.summary",
            defaultValue: "Copies the deployment branch policy (\(source.branchPolicy.localizedSummary)), \(secretCount) secrets and \(variableCount) variables. Nothing changes on GitHub until the next Sync."
        )
    }

    /// The value-missing secrets that are copied without a value (§7.8).
    var valueMissingNote: ConfigEditorNoteModel? {
        guard valueMissingCount > 0 else { return nil }
        return .warning(String(
            localized: "environment.duplicate.valueMissing",
            defaultValue: "\(valueMissingCount) secrets have no value in FX Vault. Their copies stay \u{201C}Value missing\u{201D}, and Sync skips them until you fill them."
        ))
    }

    /// Duplicates the environment. Returns true when the sheet can close.
    func duplicate() -> Bool {
        guard canDuplicate else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            createdID = try dependencies.config.duplicateEnvironment(
                context.environmentID,
                as: EnvironmentNameValidator.normalize(name)
            )
            return true
        } catch {
            alert = error.presentation
            return false
        }
    }
}
