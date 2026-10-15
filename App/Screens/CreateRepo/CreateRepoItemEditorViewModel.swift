import EnvTools
import Foundation
import Observation
import VaultCore

/// Adds or edits one staged secret or variable of the New Repository sheet (§10, §5.11).
///
/// Names follow ``GitHubNameValidator`` (uppercased on save, unique per scope and kind) and the
/// scope's capacity (``ScopeCapacityValidator``); values follow ``ValueNormalizer`` (D32). The
/// value is entered only through `SecretValueEditor` and lives here until ``save()`` hands it to
/// the parent or ``discard()`` drops it.
@Observable
final class CreateRepoItemEditorViewModel {
    let target: CreateRepoItemTargetModel
    /// "Repository" or the environment name, for the header.
    let scopeTitle: String
    /// True for a new item (the kind can still change); false when editing a staged one.
    let isNew: Bool
    var kind: ConfigKind
    var name: String
    var value: String

    @ObservationIgnored private let itemID: UUID
    /// The other items of the same scope (any kind), for the duplicate and capacity checks.
    @ObservationIgnored private let siblings: [CreateRepoItemDraftModel]
    @ObservationIgnored private let onSave: (CreateRepoItemDraftModel) -> Void

    init(
        target: CreateRepoItemTargetModel,
        scopeTitle: String,
        editing item: CreateRepoItemDraftModel?,
        kind: ConfigKind,
        siblings: [CreateRepoItemDraftModel],
        onSave: @escaping (CreateRepoItemDraftModel) -> Void
    ) {
        self.target = target
        self.scopeTitle = scopeTitle
        isNew = item == nil
        itemID = item?.id ?? UUID()
        self.kind = item?.kind ?? kind
        name = item?.name ?? ""
        value = item?.value ?? ""
        self.siblings = siblings.filter { $0.id != item?.id }
        self.onSave = onSave
    }

    // MARK: - Validation

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    /// Why the name cannot be saved; nil while the field is empty (no error before typing).
    var nameError: String? {
        guard !trimmedName.isEmpty else { return nil }
        if let rule = GitHubNameValidator.violation(in: trimmedName) {
            return rule.localizedMessage
        }
        let key = GitHubNameValidator.foldKey(trimmedName)
        if siblings.contains(where: { $0.kind == kind && $0.nameKey == key }) {
            return ValidationError.duplicateName.localizedMessage
        }
        return nil
    }

    /// A valid name close to an invalid one (`my-key` → `MY_KEY`).
    var suggestedName: String? {
        guard !trimmedName.isEmpty, GitHubNameValidator.violation(in: trimmedName) != nil else { return nil }
        return GitHubNameValidator.suggestedFix(for: trimmedName)
    }

    func applySuggestedName() {
        if let suggestedName {
            name = suggestedName
        }
    }

    /// Why the scope cannot take another item of this kind (only for new items or a kind change).
    var capacityError: String? {
        let count = siblings.count { $0.kind == kind }
        do {
            try ScopeCapacityValidator.validate(currentCount: count, kind: kind, level: target.level)
            return nil
        } catch {
            return error.localizedMessage
        }
    }

    /// Why the value cannot be saved; nil while it is empty (Save just stays disabled).
    var valueError: String? {
        guard !value.isEmpty else { return nil }
        do {
            _ = try ValueNormalizer.normalize(value)
            return nil
        } catch {
            return error.localizedMessage
        }
    }

    /// A variable whose name or value looks like a credential (§5.13): offer to keep it secret.
    var looksLikeCredential: Bool {
        kind == .variable && !value.isEmpty
            && CredentialClassifier.assess(key: trimmedName, value: value).isLikelyCredential
    }

    func makeSecret() {
        kind = .secret
    }

    var canSave: Bool {
        !trimmedName.isEmpty && nameError == nil && capacityError == nil
            && !ValueNormalizer.strippingTrailingNewlines(value).isEmpty && valueError == nil
    }

    // MARK: - Actions

    /// Hands the item to the parent (name uppercased) and forgets the value here.
    @discardableResult
    func save() -> Bool {
        guard canSave, let validName = try? GitHubNameValidator.validate(trimmedName) else { return false }
        onSave(CreateRepoItemDraftModel(id: itemID, kind: kind, name: validName, value: value))
        value = ""
        return true
    }

    /// Drops the typed value (Cancel, lock).
    func discard() {
        value = ""
    }
}
