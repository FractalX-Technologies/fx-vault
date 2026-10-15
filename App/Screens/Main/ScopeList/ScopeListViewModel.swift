import Foundation
import Observation
import VaultCore
import VaultData

/// Column 2 (§10): "Repository" then one row per environment, with the pending dot and the
/// value-missing count, "+ New Environment" and the environment context menu.
///
/// Observes `ConfigRepository.observeScopes(repositoryID:)`, so every local change (a new
/// environment, a deletion, a sync) shows at once.
@Observable
final class ScopeListViewModel {
    let repositoryID: RepoID
    private(set) var scopes: [ConfigScopeSummaryModel] = []
    var selectedScopeID: ConfigScopeSummaryModel.ID? = ScopeListViewModel.repositoryScopeID {
        didSet {
            if selectedScopeID != oldValue {
                onSelectionChange?()
            }
        }
    }
    /// The environment waiting for the "Delete environment?" confirmation.
    var pendingDeletion: ConfigScopeSummaryModel?
    var alert: ErrorPresentationModel?

    /// Called when the selected scope changes (the detail column follows it).
    @ObservationIgnored var onSelectionChange: (() -> Void)?
    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let repository: () -> RepoModel?
    @ObservationIgnored private let tasks = TaskBag()

    /// `ConfigScopeSummaryModel.id` of the repository scope.
    static let repositoryScopeID = ConfigScopeLevel.repository.rawValue

    /// - Parameter repository: the live vault row (capability, visibility).
    init(repositoryID: RepoID, dependencies: FeatureDependencies, repository: @escaping () -> RepoModel?) {
        self.repositoryID = repositoryID
        self.dependencies = dependencies
        self.repository = repository
        observe()
    }

    private func observe() {
        let stream = dependencies.config.observeScopes(repositoryID: repositoryID)
        tasks.set("scopes", Task { [weak self] in
            do {
                for try await scopes in stream {
                    self?.apply(scopes)
                }
            } catch {
                // Ends with `.repositoryNotFound` when the repository is removed from the vault.
                self?.apply([])
            }
        })
    }

    /// Applies a new snapshot; a selection that disappeared falls back to "Repository".
    func apply(_ scopes: [ConfigScopeSummaryModel]) {
        self.scopes = scopes
        if let selectedScopeID, !scopes.contains(where: { $0.id == selectedScopeID }) {
            self.selectedScopeID = scopes.isEmpty ? nil : Self.repositoryScopeID
        } else if selectedScopeID == nil, !scopes.isEmpty {
            selectedScopeID = Self.repositoryScopeID
        }
        onSelectionChange?()
    }

    // MARK: - Content

    var selectedScope: ConfigScopeSummaryModel? {
        scopes.first { $0.id == selectedScopeID }
    }

    var environments: [ConfigScopeSummaryModel] {
        scopes.filter { $0.environment != nil }
    }

    var capability: RepoCapabilityModel? {
        repository()?.capability
    }

    /// "+ New Environment" needs admin (environments always do, §2).
    var canCreateEnvironment: Bool {
        capability?.canEditEnvironments == true
    }

    /// Rename, duplicate, settings and delete need admin and a live (not deleted) environment.
    func canEdit(_ scope: ConfigScopeSummaryModel) -> Bool {
        scope.environment != nil && !scope.isDeleted && canCreateEnvironment
    }

    /// Export .env… and Share… need at least one value (and an existing scope).
    func canExport(_ scope: ConfigScopeSummaryModel) -> Bool {
        !scope.isDeleted && scope.itemCount > 0
    }

    // MARK: - Actions

    func newEnvironment() {
        guard canCreateEnvironment else { return }
        dependencies.actions.present(.newEnvironment(NewEnvironmentContext(repositoryID: repositoryID)))
    }

    func openSettings(_ scope: ConfigScopeSummaryModel) {
        guard canEdit(scope), let context = environmentContext(scope) else { return }
        dependencies.actions.present(.environmentSettings(context))
    }

    func rename(_ scope: ConfigScopeSummaryModel) {
        guard canEdit(scope), let context = environmentContext(scope) else { return }
        dependencies.actions.present(.renameEnvironment(context))
    }

    func duplicate(_ scope: ConfigScopeSummaryModel) {
        guard canEdit(scope), let context = environmentContext(scope) else { return }
        dependencies.actions.present(.duplicateEnvironment(context))
    }

    func exportEnv(_ scope: ConfigScopeSummaryModel) {
        guard canExport(scope) else { return }
        dependencies.actions.present(.envExport(EnvExportContext(repositoryID: repositoryID, scope: scope.scope)))
    }

    func share(_ scope: ConfigScopeSummaryModel) {
        guard canExport(scope) else { return }
        dependencies.actions.present(.shareExport(ShareExportContext(selection: shareSelection(for: scope))))
    }

    func shareSelection(for scope: ConfigScopeSummaryModel) -> ShareSelectionModel {
        if let environment = scope.environment {
            return .environment(environment.id)
        }
        return .repository(repositoryID)
    }

    func requestDeletion(_ scope: ConfigScopeSummaryModel) {
        guard canEdit(scope) else { return }
        pendingDeletion = scope
    }

    /// Deletes the environment: removed when never synced, otherwise a tombstone the next Sync
    /// deletes on GitHub (§7.5).
    func confirmDeletion() {
        guard let scope = pendingDeletion, let environment = scope.environment else { return }
        pendingDeletion = nil
        do {
            try dependencies.config.deleteEnvironment(environment.id)
        } catch {
            alert = error.presentation
        }
    }

    /// Restores a deleted (or renamed, or re-policied) environment to its synced state.
    func revert(_ scope: ConfigScopeSummaryModel) {
        guard let environment = scope.environment else { return }
        do {
            try dependencies.config.revertEnvironment(environment.id)
        } catch {
            alert = error.presentation
        }
    }

    /// True when the environment has a local change Revert can undo.
    func canRevert(_ scope: ConfigScopeSummaryModel) -> Bool {
        guard let environment = scope.environment, environment.isSynced else { return false }
        return environment.isDeleted || environment.hasPendingRename || environment.hasCaseOnlyRename
            || environment.hasPendingPolicyChange
    }

    private func environmentContext(_ scope: ConfigScopeSummaryModel) -> EnvironmentContext? {
        scope.environment.map { EnvironmentContext(repositoryID: repositoryID, environmentID: $0.id) }
    }
}

extension ConfigScopeSummaryModel {
    /// "Repository" or the environment's name.
    var title: String {
        environment?.name ?? String(localized: "main.scopes.repository", defaultValue: "Repository")
    }

    /// "Renamed from staging" for a pending rename on GitHub.
    var renamedFrom: String? {
        guard let environment, environment.hasPendingRename else { return nil }
        return environment.syncedName
    }
}
