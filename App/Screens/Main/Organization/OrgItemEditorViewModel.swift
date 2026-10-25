import EnvTools
import Foundation
import Observation
import VaultCore
import VaultData

/// Adds or edits an organization secret or variable (1.0, B6b3a), saved at once in the vault for
/// the next Sync. Names never change (GitHub cannot rename). A Selected item whose list GitHub
/// holds starts with nothing checked: its list is replaced only when the user picks repositories.
@Observable
final class OrgItemEditorViewModel: LockObserving {
    enum LoadState: Equatable {
        case loading
        case ready
        case unavailable(ErrorPresentationModel)
    }

    let context: OrgItemEditorContext
    private(set) var loadState: LoadState = .loading
    private(set) var organization: OrganizationModel?
    /// The edited item (nil while adding).
    private(set) var item: OrgItemModel?
    /// Every item of the organization (deletions included), for the name checks.
    private(set) var siblings: [OrgItemModel] = []

    var kind: ConfigKind
    /// Add only: uppercased as typed.
    var name = "" {
        didSet {
            let uppercased = ItemEditorViewModel.uppercasingASCII(name)
            if uppercased != name {
                name = uppercased
            }
        }
    }

    var value = "" {
        didSet {
            if value != oldValue, !isProgrammaticValueChange {
                isValueEdited = true
            }
        }
    }

    private(set) var isValueEdited = false
    /// Edit of a secret without a value: "Already matches GitHub (don't push)".
    var matchesGitHub = false
    var visibility: OrgVisibility = .all
    var selectedRepositories: Set<String> = []
    var alert: ErrorPresentationModel?

    /// The list the vault holds for the item (edited before); empty when GitHub's list stands.
    @ObservationIgnored private var storedRepositories: [String] = []
    @ObservationIgnored private var isProgrammaticValueChange = false
    @ObservationIgnored private let dependencies: FeatureDependencies

    init(context: OrgItemEditorContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
        kind = if case .add(let kind) = context.mode { kind } else { .secret }
        dependencies.actions.addLockObserver(self)
    }

    /// Reads the organization and its items, and the edited item's value (a variable) and list.
    func load() async {
        // Once: the view's task runs again when it reappears and would drop the user's choices.
        guard loadState == .loading else { return }
        do {
            organization = try await dependencies.organizations.organizations().first { $0.id == context.organizationID }
            guard organization != nil else { throw ConfigRepositoryError.organizationNotFound }
            siblings = try await dependencies.organizations.items(of: context.organizationID)
            if case .edit(let id) = context.mode {
                try prepare(id)
            }
            loadState = .ready
        } catch let error as RepoCatalogError {
            loadState = .unavailable(error.presentation)
        } catch let error as ConfigRepositoryError {
            loadState = .unavailable(error.presentation)
        } catch {
            loadState = .unavailable(ConfigRepositoryError.unexpected.presentation)
        }
    }

    private func prepare(_ id: ConfigItemID) throws(ConfigRepositoryError) {
        guard let item = siblings.first(where: { $0.id == id }), item.syncStatus != .deleted else {
            throw .itemNotFound
        }
        self.item = item
        kind = item.kind
        name = item.name
        visibility = item.visibility
        storedRepositories = try dependencies.organizationItems.repositories(of: id)
        selectedRepositories = Set(storedRepositories)
        if item.kind == .variable, item.hasValue {
            let bytes = try dependencies.organizationItems.reveal(id)
            defer { bytes.wipe() }
            guard let text = bytes.utf8String() else { throw .unexpected }
            setValueProgrammatically(text)
        }
    }

    // MARK: - Mode

    var isAdding: Bool {
        item == nil
    }

    var title: String {
        if let item { return item.name }
        return kind == .secret
            ? String(localized: "organization.editor.newSecret", defaultValue: "New Secret")
            : String(localized: "organization.editor.newVariable", defaultValue: "New Variable")
    }

    var subtitle: String? {
        organization.map { String(localized: "organization.editor.subtitle", defaultValue: "In the organization \($0.login)") }
    }

    var primaryTitle: String {
        isAdding
            ? String(localized: "itemEditor.save.add", defaultValue: "Add")
            : String(localized: "itemEditor.save.edit", defaultValue: "Save")
    }

    // MARK: - Name

    var normalizedName: String {
        GitHubNameValidator.normalize(name)
    }

    private func hasTypedName(_ sibling: OrgItemModel) -> Bool {
        sibling.kind == kind && GitHubNameValidator.foldKey(sibling.name) == GitHubNameValidator.foldKey(name)
    }

    private var isNameTaken: Bool {
        isAdding && siblings.contains { hasTypedName($0) && $0.syncStatus != .deleted }
    }

    var nameNote: ConfigEditorNoteModel? {
        guard isAdding, !name.isEmpty else { return nil }
        if let rule = GitHubNameValidator.violation(in: name) {
            return .error(rule.localizedMessage)
        }
        if isNameTaken {
            return .error(String(
                localized: "organization.editor.nameTaken",
                defaultValue: "This organization already has an item of this kind with this name."
            ))
        }
        if siblings.contains(where: { hasTypedName($0) && $0.syncStatus == .deleted }) {
            return .info(String(
                localized: "organization.editor.nameRevives",
                defaultValue: "\(normalizedName) is pending deletion. Adding it restores it with the new value instead."
            ))
        }
        return nil
    }

    var suggestedName: String? {
        guard isAdding, !name.isEmpty else { return nil }
        return GitHubNameValidator.suggestedFix(for: name)
    }

    func applySuggestedName() {
        guard let suggestedName else { return }
        name = suggestedName
    }

    // MARK: - Value

    /// Editing a secret that has a value: an empty editor keeps it.
    private var keepsValueWhenEmpty: Bool {
        item?.kind == .secret && item?.hasValue == true
    }

    /// The value the save writes, or nil when it keeps the current one.
    private var newValue: String? {
        guard item != nil else { return value }
        if !isValueEdited || (keepsValueWhenEmpty && value.isEmpty) { return nil }
        return value
    }

    var valueNotes: [ConfigEditorNoteModel] {
        ItemValueRules.notes(
            for: value,
            isEmptyAnError: item != nil && isValueEdited && !keepsValueWhenEmpty,
            keepsCurrent: keepsValueWhenEmpty
        )
    }

    /// "Already matches GitHub" is offered for a secret GitHub never returned a value for.
    var offersFillChoice: Bool {
        item?.kind == .secret && item?.hasValue == false
    }

    var credentialWarning: CredentialWarningModel? {
        guard kind == .variable else { return nil }
        let assessment = CredentialClassifier.assess(key: name, value: value)
        guard assessment.isLikelyCredential else { return nil }
        return CredentialWarningModel(reasons: assessment.reasons.map(\.editorExplanation), action: isAdding ? .switchToSecret : nil)
    }

    // MARK: - Access

    /// The organization's repositories with the ones already chosen, by name.
    var repositoryOptions: [String] {
        Set(context.repositoryCandidates).union(selectedRepositories)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func setRepository(_ name: String, selected: Bool) {
        if selected {
            selectedRepositories.insert(name)
        } else {
            selectedRepositories.remove(name)
        }
    }

    /// True when the save replaces who can use the item.
    private var isAccessChanged: Bool {
        guard let item else { return true }
        if visibility != item.visibility { return true }
        guard visibility == .selected else { return false }
        return selectedRepositories != Set(storedRepositories) && !selectedRepositories.isEmpty
    }

    /// The access the save sends; nil while Selected has nothing to send.
    private var access: OrgItemAccessModel? {
        switch visibility {
        case .all: .all
        case .private: .private
        case .selected: selectedRepositories.isEmpty ? nil : .selected(selectedRepositories.sorted())
        }
    }

    var accessNote: ConfigEditorNoteModel? {
        guard visibility == .selected, selectedRepositories.isEmpty else { return nil }
        if let item, item.visibility == .selected, storedRepositories.isEmpty {
            return .info(String(
                localized: "organization.editor.access.githubList",
                defaultValue: "GitHub's repository list stays unless you pick repositories here."
            ))
        }
        return .error(String(localized: "organization.editor.access.pickOne", defaultValue: "Pick at least one repository."))
    }

    // MARK: - Save

    var canSave: Bool {
        guard loadState == .ready, ItemValueRules.isValid(newValue), accessNote?.isError != true else { return false }
        guard isAdding else { return newValue != nil || isAccessChanged }
        return GitHubNameValidator.isValid(name) && !isNameTaken
    }

    /// Saves; returns true when the sheet can close.
    func save() -> Bool {
        guard canSave else { return false }
        do {
            if let item {
                try saveEdit(item)
            } else {
                guard let access else { return false }
                let bytes = SecretBytes(utf8: value)
                defer { bytes.wipe() }
                try dependencies.organizationItems.addItem(
                    organizationID: context.organizationID,
                    kind: kind,
                    name: normalizedName,
                    value: bytes,
                    access: access
                )
            }
        } catch {
            alert = error.presentation
            return false
        }
        clearValue()
        return true
    }

    private func saveEdit(_ item: OrgItemModel) throws(ConfigRepositoryError) {
        if let newValue {
            let bytes = SecretBytes(utf8: newValue)
            defer { bytes.wipe() }
            try dependencies.organizationItems.setValue(item.id, value: bytes, alreadyMatchesRemote: offersFillChoice && matchesGitHub)
        }
        if isAccessChanged, let access {
            try dependencies.organizationItems.setAccess(item.id, access)
        }
    }

    // MARK: - Value hygiene

    private func setValueProgrammatically(_ text: String) {
        isProgrammaticValueChange = true
        value = text
        isProgrammaticValueChange = false
    }

    /// Drops the typed or decrypted value (save, lock, sheet closing).
    func clearValue() {
        setValueProgrammatically("")
        isValueEdited = false
    }

    func vaultDidLock() {
        clearValue()
    }
}
