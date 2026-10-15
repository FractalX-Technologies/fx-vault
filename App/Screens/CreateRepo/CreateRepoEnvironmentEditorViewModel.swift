import Foundation
import Observation
import VaultCore
import VaultData

/// Adds or edits one staged environment of the New Repository sheet: its name
/// (``EnvironmentNameValidator``, unique by fold key among the staged environments) and its
/// deployment branch policy (all, protected branches, or selected branch and tag patterns,
/// ``BranchPatternValidator``, at most `Limits.maxBranchPatternsPerEnvironment`). It never holds
/// the environment's items: the parent keeps them when it applies the result.
@Observable
final class CreateRepoEnvironmentEditorViewModel {
    let isNew: Bool
    var name: String
    /// The deployment branch policy, edited with the shared `BranchPolicyEditorView`.
    var policyForm: BranchPolicyFormModel

    @ObservationIgnored private let environmentID: UUID
    @ObservationIgnored private let takenKeys: Set<String>
    @ObservationIgnored private let onSave: (CreateRepoEnvironmentDraftModel) -> Void

    init(
        editing environment: CreateRepoEnvironmentDraftModel?,
        otherEnvironments: [CreateRepoEnvironmentDraftModel],
        onSave: @escaping (CreateRepoEnvironmentDraftModel) -> Void
    ) {
        isNew = environment == nil
        environmentID = environment?.id ?? UUID()
        name = environment?.name ?? ""
        policyForm = BranchPolicyFormModel(environment?.policy ?? .all)
        takenKeys = Set(otherEnvironments.filter { $0.id != environment?.id }.map(\.nameKey))
        self.onSave = onSave
    }

    // MARK: - Name

    /// Why the name cannot be saved; nil while the field is empty.
    var nameError: String? {
        guard !name.isEmpty else { return nil }
        do {
            try EnvironmentNameValidator.validate(name)
            try EnvironmentNameValidator.checkAvailability(of: name, takenKeys: takenKeys)
            return nil
        } catch {
            return error.localizedMessage
        }
    }

    // MARK: - Policy

    /// Selected branches and tags needs at least one rule (otherwise no branch could deploy).
    var needsPattern: Bool {
        policyForm.choice == .selected && policyForm.patterns.isEmpty
    }

    var policy: BranchPolicyDraftModel {
        policyForm.draft
    }

    // MARK: - Save

    /// A valid name, a valid policy with at least one rule when selected, and no rule typed but
    /// not added (Return in the rule field adds it instead of saving without it).
    var canSave: Bool {
        !name.isEmpty && nameError == nil && !needsPattern && policyForm.isReadyToSave
    }

    @discardableResult
    func save() -> Bool {
        guard canSave, let validName = try? EnvironmentNameValidator.validate(name) else { return false }
        onSave(CreateRepoEnvironmentDraftModel(id: environmentID, name: validName, policy: policy))
        return true
    }
}
