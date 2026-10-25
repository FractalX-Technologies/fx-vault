import EnvTools
import Foundation
import Observation
import VaultCore
import VaultData

/// "+ Add Destination" (v0.8.0, tasks/todo.md R7): the stage and a Key Vault (name and optional
/// tenant). Adding imports what the vault already holds.
@Observable
final class AddDestinationViewModel: LockObserving {
    enum Phase: Equatable {
        case form
        case working
        /// Added; the import's outcome (or why it could not run).
        case done(DestinationAddedModel)
    }

    let context: AddDestinationContext
    var stage: String = ""
    private(set) var stageSuggestions: [String] = []

    var vaultName = ""
    var tenantID = ""

    private(set) var phase: Phase = .form
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let tasks = TaskBag()

    init(context: AddDestinationContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
        dependencies.actions.addLockObserver(self)
        loadStages()
    }

    private func loadStages() {
        stageSuggestions = (try? dependencies.destinations.stageSuggestions(repositoryID: context.repositoryID)) ?? []
        if stage.isEmpty {
            stage = stageSuggestions.first { EnvironmentNameValidator.foldKey($0) == Self.defaultStage } ?? stageSuggestions.first ?? Self.defaultStage
        }
    }

    // MARK: - Form

    var title: String {
        AddDestinationCopy.title
    }

    /// The target the fields describe, or nil while the vault name is empty.
    var target: DestinationTargetModel? {
        let name = vaultName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return .azureKeyVault(vaultName: name, tenantID: tenantID.isEmpty ? nil : tenantID)
    }

    /// Why the target cannot be added yet (shown under the fields), or nil.
    var targetProblem: String? {
        guard let target else { return nil }
        do {
            _ = try DestinationRules.validate(target)
            return nil
        } catch {
            return error.localizedMessage
        }
    }

    var stageProblem: String? {
        let trimmed = stage.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return EnvironmentNameValidator.violation(in: trimmed)?.localizedMessage
    }

    var canAdd: Bool {
        phase == .form && target != nil && targetProblem == nil && stageProblem == nil && dependencies.connectivity.isOnline
    }

    // MARK: - Add

    /// Adds the destination, then imports what it already holds.
    func add() {
        guard canAdd, let target else { return }
        let trimmedStage = stage.trimmingCharacters(in: .whitespaces)
        let id: DestinationID
        do {
            id = try dependencies.destinations.createDestination(
                repositoryID: context.repositoryID,
                target: target,
                stage: trimmedStage.isEmpty ? nil : trimmedStage
            )
        } catch {
            alert = error.presentation
            return
        }
        phase = .working
        let sync = dependencies.destinationSync
        tasks.set("import", Task { [weak self] in
            let outcome: DestinationAddedModel
            do throws(DestinationSyncError) {
                outcome = DestinationAddedModel(destinationID: id, result: try await sync.importRemote(destinationID: id), importError: nil)
            } catch {
                outcome = DestinationAddedModel(destinationID: id, result: nil, importError: error.presentation(provider: target.provider).message)
            }
            self?.phase = .done(outcome)
        })
    }

    /// Done: shows the new destination.
    func openDestination() {
        guard case .done(let added) = phase else { return }
        dependencies.actions.openPlace(.destination(added.destinationID))
    }

    private static let defaultStage = "production"

    // MARK: - LockObserving

    func vaultDidLock() {
        tasks.cancelAll()
    }
}

/// The outcome of Add Destination: the import's result, or why it could not run (the
/// destination stays; Refresh imports later).
struct DestinationAddedModel: Equatable {
    let destinationID: DestinationID
    let result: DestinationImportResultModel?
    let importError: String?
}
