import Foundation
import Observation
import VaultCore
import VaultData

/// The scopes of one repository (§10): the repository scope, which its sidebar row stands for,
/// then one row per environment nested under it (1.0), with the pending dot and the
/// value-missing count, "+ New Environment" and the environment context menu. Since v0.8.0
/// (tasks/todo.md R7) also the RUNTIME destinations with "+ Add Destination"; a selection is a
/// scope or a destination.
///
/// Observes `ConfigRepository.observeScopes(repositoryID:)` and
/// `DestinationRepository.observeDestinations(repositoryID:)`, so every local change (a new
/// environment or destination, a deletion, a sync) shows at once.
@Observable
final class ScopeListViewModel {
    let repositoryID: RepoID
    private(set) var scopes: [ConfigScopeSummaryModel] = []
    /// The repository's runtime destinations (v0.8.0), in their order.
    private(set) var destinations: [DestinationModel] = []
    /// The destination waiting for the "Remove destination?" confirmation.
    var pendingDestinationRemoval: DestinationModel?
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
    /// A scope asked for before the scopes arrived (opening a linked copy, v0.4.1).
    @ObservationIgnored private var requestedScope: ConfigScope?
    /// A destination asked for before the destinations arrived (v0.8.0).
    @ObservationIgnored private var requestedDestination: DestinationID?
    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let repository: () -> RepoModel?
    @ObservationIgnored private let tasks = TaskBag()

    /// `ConfigScopeSummaryModel.id` of the repository scope.
    static let repositoryScopeID = ConfigScopeLevel.repository.rawValue
    private static let destinationIDPrefix = "destination|"

    /// The selection id of a destination row (v0.8.0).
    static func selectionID(of destination: DestinationID) -> String {
        destinationIDPrefix + destination.uuidString
    }

    /// - Parameter repository: the live vault row (capability, visibility).
    init(repositoryID: RepoID, dependencies: FeatureDependencies, repository: @escaping () -> RepoModel?) {
        self.repositoryID = repositoryID
        self.dependencies = dependencies
        self.repository = repository
        observe()
        observeDestinations()
    }

    private func observeDestinations() {
        let stream = dependencies.destinations.observeDestinations(repositoryID: repositoryID)
        tasks.set("destinations", Task { [weak self] in
            do {
                for try await destinations in stream {
                    self?.apply(destinations: destinations)
                }
            } catch {
                self?.apply(destinations: [])
            }
        })
    }

    /// Applies a new snapshot of the destinations; a selected destination that disappeared falls
    /// back to "Repository".
    func apply(destinations: [DestinationModel]) {
        self.destinations = destinations
        if let requestedDestination, destinations.contains(where: { $0.id == requestedDestination }) {
            self.requestedDestination = nil
            selectedScopeID = Self.selectionID(of: requestedDestination)
        }
        if let selectedScopeID, selectedScopeID.hasPrefix(Self.destinationIDPrefix), selectedDestination == nil {
            self.selectedScopeID = scopes.isEmpty ? nil : Self.repositoryScopeID
        }
        onSelectionChange?()
    }

    /// Selects a destination now, or as soon as the destinations include it.
    func select(destination: DestinationID) {
        if destinations.contains(where: { $0.id == destination }) {
            requestedDestination = nil
            selectedScopeID = Self.selectionID(of: destination)
        } else {
            requestedDestination = destination
        }
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

    /// Selects `scope` now, or as soon as the scopes include it.
    func select(scope: ConfigScope) {
        if let summary = scopes.first(where: { $0.scope == scope }) {
            requestedScope = nil
            selectedScopeID = summary.id
        } else {
            requestedScope = scope
        }
    }

    /// Applies a new snapshot; a selection that disappeared falls back to "Repository".
    func apply(_ scopes: [ConfigScopeSummaryModel]) {
        self.scopes = scopes
        if let requestedScope, let summary = scopes.first(where: { $0.scope == requestedScope }) {
            self.requestedScope = nil
            selectedScopeID = summary.id
        }
        if let selectedScopeID, !isOtherSelectionID(selectedScopeID), !scopes.contains(where: { $0.id == selectedScopeID }) {
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

    /// The selected destination (v0.8.0), or nil.
    var selectedDestination: DestinationModel? {
        guard let selectedScopeID, selectedScopeID.hasPrefix(Self.destinationIDPrefix) else { return nil }
        return destinations.first { Self.selectionID(of: $0.id) == selectedScopeID }
    }

    /// The live destination with `id` (the detail column reads its counts).
    func destination(_ id: DestinationID) -> DestinationModel? {
        destinations.first { $0.id == id }
    }

    /// Every row id in column order, for Up and Down.
    /// The environments, in order: the rows nested under the repository's sidebar row.
    var environmentScopes: [ConfigScopeSummaryModel] {
        scopes.filter { $0.environment != nil }
    }

    /// Up and Down walk the repository scope (its sidebar row), the environments, then the
    /// destinations.
    var rowIDs: [String] {
        scopes.map(\.id) + destinations.map { Self.selectionID(of: $0.id) }
    }

    /// Destination ids are not scopes: a scope snapshot never resets them.
    private func isOtherSelectionID(_ id: String) -> Bool {
        id.hasPrefix(Self.destinationIDPrefix)
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

    // MARK: - Destinations (v0.8.0)

    /// "+ Add Destination": any account that imported the repository may add one; the provider
    /// decides what it may write.
    func addDestination() {
        dependencies.actions.present(.addDestination(AddDestinationContext(repositoryID: repositoryID)))
    }

    /// Settings…: the stage.
    func openSettings(_ destination: DestinationModel) {
        dependencies.actions.present(.destinationSettings(DestinationSettingsContext(destinationID: destination.id)))
    }

    func exportEnv(_ destination: DestinationModel) {
        guard destination.itemCount > 0 else { return }
        dependencies.actions.present(.envExport(EnvExportContext(destinationID: destination.id)))
    }

    func requestRemoval(_ destination: DestinationModel) {
        pendingDestinationRemoval = destination
    }

    /// Removes the destination from the vault (nothing is deleted remotely).
    func confirmRemoval() {
        guard let destination = pendingDestinationRemoval else { return }
        pendingDestinationRemoval = nil
        do {
            try dependencies.destinations.deleteDestination(destination.id)
        } catch {
            alert = error.presentation
        }
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
