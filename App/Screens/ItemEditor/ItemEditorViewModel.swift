import EnvTools
import Foundation
import Observation
import VaultCore
import VaultData

/// `ConfigItemEditorScreen` (§10 Sheets, §7.1, §7.8, D11, D32): add or edit a secret or
/// variable, fill a value-missing secret, or convert/move an item to another kind or scope.
///
/// - Names are uppercased as typed (ASCII only, so `ß` is still rejected instead of becoming
///   `SS`), validated live with `GitHubNameValidator` and checked against the scope's other
///   items by fold key; an invalid name offers `suggestedFix`.
/// - Values come only from `SecretValueEditor`. Trailing CR/LF are stripped on save (D32); the
///   editor says so before saving, and `ConfigRepository` normalizes again. A secret being
///   edited starts empty (keep the current value) unless the user asks for the current value; a
///   variable starts with its value (variables are shown in plaintext, §10).
/// - Kind and scope are locked once the item is on GitHub (D11); Convert/Move goes through
///   `ConfigRepository.moveItem`, and secret → variable asks for confirmation first (§5.13).
/// - A variable that looks like a credential (`CredentialClassifier`) gets a warning that
///   suggests a secret.
/// - The vault is the source of truth (v0.1.2): filling a secret that is on GitHub pushes it on
///   the next Sync unless "Already matches GitHub (don't push)" is checked (off by default; on
///   when the editor continues a drift "Accept GitHub"). Editing a synced secret offers "Push on
///   Next Sync", which re-sends the value even when it did not change.
/// - The value lives only in this view model's `value` while the sheet is open; it is dropped
///   after a save and on lock, and never appears in notes, warnings, alerts or logs.
/// - A linked item (v0.4.1, L4) lists its other places when a new value is entered: the ones
///   that still have the item's current value start checked, the ones the account cannot change
///   are disabled. Saving updates the checked copies too (`ConfigRepository.updateLinkedCopies`).
/// - A folder item (v0.7.0) is added and edited the same way (``ItemEditorContext/place``), saved
///   at once through `FolderRepository`; it has no fill, move or push, and its kind stays
///   editable.
@Observable
final class ItemEditorViewModel: LockObserving {
    enum LoadState: Equatable {
        case loading
        case ready
        /// The item or scope cannot be edited (deleted, gone, already filled).
        case unavailable(ErrorPresentationModel)
    }

    let context: ItemEditorContext
    private(set) var loadState: LoadState = .loading
    /// The edited item (nil while adding).
    private(set) var item: EditorItemModel?
    private(set) var repository: RepoModel?
    /// The folder of a folder item (v0.7.0).
    private(set) var folder: FolderModel?
    /// The live scopes of the repository (Convert/Move targets and scope titles).
    private(set) var scopeOptions: [ItemScopeOptionModel] = []
    /// Every item of the context scope or folder (tombstones included), for duplicate checks.
    private(set) var siblings: [EditorItemModel] = []

    /// Add and edit: the kind picker (locked once synced, D11).
    var kind: ConfigKind
    /// Add and edit: uppercased as typed.
    var name = "" {
        didSet {
            let uppercased = Self.uppercasingASCII(name)
            if uppercased != name {
                name = uppercased
            }
        }
    }

    /// The value in `SecretValueEditor`.
    var value = "" {
        didSet {
            if value != oldValue, !isProgrammaticValueChange {
                isValueEdited = true
            }
        }
    }

    /// True once the user changed the value.
    private(set) var isValueEdited = false
    /// True once the current secret value was decrypted into the editor ("Edit Current Value").
    private(set) var isCurrentValueLoaded = false
    /// Fill: "Already matches GitHub (don't push)". Off by default, so the filled value is
    /// pushed by the next Sync (v0.1.2).
    var fillMatchesGitHub: Bool
    /// Edit: "Push on Next Sync" for a synced secret, applied on Save (v0.1.2).
    var pushOnNextSync = false
    /// Convert/Move: the target kind and scope.
    var targetKind: ConfigKind
    var targetScope: ConfigScope
    /// The pending secret → variable confirmation.
    var confirmation: ItemEditorConfirmationModel?
    var alert: ErrorPresentationModel?
    /// The other places of a linked item being edited (v0.4.1), compared with its current value.
    private(set) var linkedCopies: [LinkedCopyModel] = []
    /// The linked copies the save also updates.
    var linkedSelection: Set<ConfigItemID> = []
    private(set) var isSaving = false
    /// True when the last save stripped trailing CR/LF (D32).
    private(set) var didStripTrailingNewlines = false

    @ObservationIgnored private var isProgrammaticValueChange = false
    @ObservationIgnored private let dependencies: FeatureDependencies

    init(context: ItemEditorContext, dependencies: FeatureDependencies) {
        self.context = context
        self.dependencies = dependencies
        let initialKind: ConfigKind = if case .add(let kind) = context.mode { kind } else { .secret }
        kind = initialKind
        targetKind = initialKind
        fillMatchesGitHub = context.fillMatchesGitHub
        targetScope = Self.scope(of: context.place)
        dependencies.actions.addLockObserver(self)
    }

    /// The context's scope; `.repository` for a folder, which has none.
    private static func scope(of place: ItemPlaceModel) -> ConfigScope {
        if case .scope(_, let scope) = place { return scope }
        return .repository
    }

    /// The context's scope (see ``scope(of:)``).
    private var scope: ConfigScope {
        Self.scope(of: context.place)
    }

    // MARK: - Loading

    /// Reads the repository, the scopes and the scope's items (or the folder and its items).
    /// Call once when the sheet opens.
    func load() async {
        if case .folder(let folderID) = context.place {
            await loadFolder(folderID)
            return
        }
        guard case .scope(let repositoryID, let scope) = context.place else { return }
        do {
            let config = dependencies.config
            let repository = try config.editorRepository(repositoryID)
            let scopes = try config.scopes(repositoryID: repositoryID)
            if let current = scopes.first(where: { $0.scope == scope }), current.isDeleted {
                throw ConfigRepositoryError.environmentDeleted
            }
            guard scopes.contains(where: { $0.scope == scope }) else {
                throw ConfigRepositoryError.environmentNotFound
            }
            let items = try await config.editorItems(repositoryID: repositoryID, scope: scope).map(EditorItemModel.init)
            self.repository = repository
            siblings = items
            scopeOptions = scopes.filter { !$0.isDeleted }.map { summary in
                ItemScopeOptionModel(
                    scope: summary.scope,
                    title: Self.title(of: summary),
                    isEditable: repository.capability.canEditItems(at: summary.scope.level)
                )
            }
            if let id = editedID {
                try prepare(itemID: id, in: items)
            }
            loadState = .ready
        } catch {
            loadState = .unavailable(error.presentation)
        }
    }

    /// A folder item's sheet: the folder and its items.
    private func loadFolder(_ folderID: FolderID) async {
        do {
            guard let folder = try dependencies.folders.folders().first(where: { $0.id == folderID }) else {
                throw ConfigRepositoryError.folderNotFound
            }
            let items = try dependencies.folders.items(folderID: folderID).map(EditorItemModel.init)
            self.folder = folder
            siblings = items
            if let id = editedID {
                guard case .edit = context.mode else { throw ConfigRepositoryError.itemNotFound }
                try prepare(itemID: id, in: items)
            }
            loadState = .ready
        } catch {
            loadState = .unavailable(error.presentation)
        }
    }

    private func prepare(itemID: ConfigItemID, in items: [EditorItemModel]) throws {
        guard let item = items.first(where: { $0.id == itemID }) else {
            throw ConfigRepositoryError.itemNotFound
        }
        guard !item.isDeleted else {
            throw ItemEditorError.deleted
        }
        self.item = item
        kind = item.kind
        name = item.name
        switch context.mode {
        case .add:
            break
        case .edit:
            if item.kind == .variable, item.hasValue {
                try loadValue(of: item.id)
            }
            if item.isLinked {
                linkedCopies = try dependencies.config.linkedCopies(of: item.id)
                linkedSelection = Set(linkedCopies.filter { $0.isEditable && $0.comparison == .same }.map(\.itemID))
            }
        case .fill:
            guard item.kind == .secret, !item.hasValue else {
                throw ConfigRepositoryError.edit(.valueNotMissing)
            }
        case .move:
            let opposite = item.kind.editorOpposite
            targetKind = canMove(to: opposite) ? opposite : item.kind
            targetScope = item.scope ?? .repository
        }
    }

    /// Decrypts the item's value into the editor (variables on open, secrets on request).
    private func loadValue(of id: ConfigItemID) throws(ConfigRepositoryError) {
        let bytes = try dependencies.config.reveal(id)
        defer { bytes.wipe() }
        guard let text = bytes.utf8String() else { throw .unexpected }
        setValueProgrammatically(text)
        isCurrentValueLoaded = true
    }

    /// "Edit Current Value": decrypts the secret's value into the editor (an explicit edit,
    /// §5.12).
    func loadCurrentValue() {
        guard let item, item.hasValue, !isCurrentValueLoaded else { return }
        do {
            try loadValue(of: item.id)
            isValueEdited = false
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - Mode

    var mode: ItemEditorContext.Mode {
        context.mode
    }

    private var editedID: ConfigItemID? {
        switch context.mode {
        case .add: nil
        case .edit(let id), .fill(let id), .move(let id): id
        }
    }

    var isAdding: Bool {
        if case .add = context.mode { return true }
        return false
    }

    var isEditing: Bool {
        if case .edit = context.mode { return true }
        return false
    }

    var isFilling: Bool {
        if case .fill = context.mode { return true }
        return false
    }

    var isMoving: Bool {
        if case .move = context.mode { return true }
        return false
    }

    /// The kind the item has after the save.
    var effectiveKind: ConfigKind {
        isMoving ? targetKind : kind
    }

    // MARK: - Header

    var title: String {
        let itemName = item?.name ?? ""
        return switch context.mode {
        case .add(_) where kind == .secret:
            String(localized: "itemEditor.title.addSecret", defaultValue: "New Secret")
        case .add:
            String(localized: "itemEditor.title.addVariable", defaultValue: "New Variable")
        case _ where item == nil:
            // Still loading, or the item is gone (the form explains why).
            String(localized: "itemEditor.title", defaultValue: "Secret or Variable")
        case .edit:
            String(localized: "itemEditor.title.edit", defaultValue: "Edit \(itemName)")
        case .fill:
            String(localized: "itemEditor.title.fill", defaultValue: "Fill Value of \(itemName)")
        case .move:
            String(localized: "itemEditor.title.move", defaultValue: "Convert or Move \(itemName)")
        }
    }

    /// "In production of owner/name", or "In the folder Mobile App" (v0.7.0).
    var subtitle: String? {
        if let folder {
            return String(localized: "itemEditor.subtitle.folder", defaultValue: "In the folder \(folder.name)")
        }
        guard let repository else { return nil }
        return String(
            localized: "itemEditor.subtitle",
            defaultValue: "In \(scopeTitle(scope)) of \(repository.fullName)"
        )
    }

    func scopeTitle(_ scope: ConfigScope) -> String {
        if let folder { return folder.name }
        return scopeOptions.first { $0.scope == scope }?.title ?? Self.repositoryTitle
    }

    // MARK: - Capability

    /// Why the context scope is read-only, or nil when it can be changed (a folder always can).
    var readOnlyReason: RepoCapabilityModel.ReadOnlyReason? {
        repository?.capability.readOnlyReason(for: scope.level)
    }

    var canEdit: Bool {
        loadState == .ready && readOnlyReason == nil
    }

    // MARK: - Kind

    /// The kind picker can change (adding, or editing an item not yet on GitHub).
    var isKindEditable: Bool {
        switch context.mode {
        case .add: true
        case .edit: item?.isKindAndScopeLocked == false
        case .fill, .move: false
        }
    }

    /// Why the kind is locked while editing a synced item (D11).
    var kindLockNote: ConfigEditorNoteModel? {
        guard isEditing, let item, item.isKindAndScopeLocked else { return nil }
        return .info(String(
            localized: "itemEditor.kind.locked",
            defaultValue: "The kind and scope cannot change once \(item.name) is on GitHub. Use Convert or Move instead."
        ))
    }

    // MARK: - Name

    var isNameEditable: Bool {
        isAdding || isEditing
    }

    /// The stored form of the typed name.
    var normalizedName: String {
        GitHubNameValidator.normalize(name)
    }

    private var isNameChanged: Bool {
        guard let item else { return true }
        return normalizedName != item.name
    }

    private var nameKey: String {
        GitHubNameValidator.foldKey(name)
    }

    /// Kinds the name must be free in: the final kind, and the current kind while a rename runs
    /// before a kind change.
    private var nameCheckKinds: Set<ConfigKind> {
        var kinds: Set<ConfigKind> = [kind]
        if let item {
            kinds.insert(item.kind)
        }
        return kinds
    }

    /// Another live item of this scope and kind already uses the name.
    var isNameTaken: Bool {
        guard isNameEditable, isNameChanged else { return false }
        return siblings.contains { sibling in
            sibling.id != editedID && !sibling.isDeleted && nameCheckKinds.contains(sibling.kind)
                && sibling.nameKey == nameKey
        }
    }

    /// A deleted item of this scope and kind with the name: adding or renaming revives it
    /// (§7.1).
    private var revivedSibling: EditorItemModel? {
        guard isNameEditable, isNameChanged, !isNameTaken else { return nil }
        return siblings.first { $0.id != editedID && $0.isDeleted && $0.kind == kind && $0.nameKey == nameKey }
    }

    var isNameValid: Bool {
        GitHubNameValidator.isValid(name) && !isNameTaken
    }

    /// Live feedback under the name field (nothing while it is empty).
    var nameNote: ConfigEditorNoteModel? {
        guard isNameEditable, !name.isEmpty else { return nil }
        if let rule = GitHubNameValidator.violation(in: name) {
            return .error(rule.localizedMessage)
        }
        if isNameTaken {
            return .error(String(
                localized: "itemEditor.name.taken",
                defaultValue: "Another item of this kind in \(scopeTitle(scope)) already uses this name."
            ))
        }
        if revivedSibling != nil {
            return .info(String(
                localized: "itemEditor.name.revives",
                defaultValue: "\(normalizedName) is pending deletion here. Saving restores it with the new value instead."
            ))
        }
        if let item, item.isSynced, isNameChanged, let syncedName = item.syncedName {
            return .info(String(
                localized: "itemEditor.name.renameOnGitHub",
                defaultValue: "GitHub cannot rename items: the next Sync creates \(normalizedName) and deletes \(syncedName)."
            ))
        }
        return nil
    }

    /// A valid name close to the typed one (`GitHubNameValidator.suggestedFix`).
    var suggestedName: String? {
        guard isNameEditable, !name.isEmpty else { return nil }
        return GitHubNameValidator.suggestedFix(for: name)
    }

    func applySuggestedName() {
        guard let suggestedName else { return }
        name = suggestedName
    }

    // MARK: - Value

    var showsValueEditor: Bool {
        !isMoving
    }

    /// Editing a secret: an empty editor keeps the current value.
    var keepsValueWhenEmpty: Bool {
        isEditing && item?.kind == .secret
    }

    /// "Edit Current Value" is offered for a secret whose value is in the vault.
    var canLoadCurrentValue: Bool {
        keepsValueWhenEmpty && item?.hasValue == true && !isCurrentValueLoaded && canEdit
    }

    private var normalizedValueByteCount: Int {
        ValueNormalizer.strippingTrailingNewlines(value).utf8.count
    }

    private var hasTrailingNewlines: Bool {
        normalizedValueByteCount != value.utf8.count
    }

    /// The value the save writes, or nil when it keeps the current one.
    private var newValue: String? {
        switch context.mode {
        case .add, .fill:
            value
        case .edit:
            if !isValueEdited { nil } else if keepsValueWhenEmpty, value.isEmpty { nil } else { value }
        case .move:
            nil
        }
    }

    private var isValueValid: Bool {
        guard newValue != nil else { return true }
        return (1...Limits.maxValueBytes).contains(normalizedValueByteCount)
    }

    /// Feedback under the value editor: size and emptiness errors, and the D32 notice before
    /// the editor commits (the editor shows its own notice after it strips).
    var valueNotes: [ConfigEditorNoteModel] {
        guard showsValueEditor else { return [] }
        var notes: [ConfigEditorNoteModel] = []
        if normalizedValueByteCount > Limits.maxValueBytes {
            notes.append(.error(ValidationError.valueTooLarge(limit: Limits.maxValueBytes).localizedMessage))
        } else if !value.isEmpty, normalizedValueByteCount == 0 {
            notes.append(.error(ValidationError.emptyValue.localizedMessage))
        } else if isEditing, isValueEdited, !keepsValueWhenEmpty, value.isEmpty {
            notes.append(.error(ValidationError.emptyValue.localizedMessage))
        }
        if hasTrailingNewlines {
            notes.append(.info(String(
                localized: "itemEditor.value.trailingNewlines",
                defaultValue: "Trailing line breaks are removed when you save. GitHub removes them too, so FX Vault stores the value as GitHub will."
            )))
        }
        if keepsValueWhenEmpty, !isCurrentValueLoaded, value.isEmpty {
            notes.append(.info(String(
                localized: "itemEditor.value.keep",
                defaultValue: "Leave the value empty to keep the current one."
            )))
        }
        return notes
    }

    // MARK: - Credential warning (§5.13)

    /// Shown while a variable's name or value looks like a credential.
    var credentialWarning: CredentialWarningModel? {
        guard !isMoving, !isFilling, effectiveKind == .variable else { return nil }
        let assessment = CredentialClassifier.assess(key: name, value: value)
        guard assessment.isLikelyCredential else { return nil }
        let action: CredentialWarningModel.Action? = if isKindEditable {
            .switchToSecret
        } else if canEdit, item != nil {
            .convertToSecret
        } else {
            nil
        }
        return CredentialWarningModel(reasons: assessment.reasons.map(\.editorExplanation), action: action)
    }

    /// The warning's action: make it a secret here, or open Convert or Move for a synced item.
    func resolveCredentialWarning() {
        guard let action = credentialWarning?.action else { return }
        switch action {
        case .switchToSecret:
            kind = .secret
        case .convertToSecret:
            guard let item, let repositoryID = context.place.repositoryID, let itemScope = item.scope else { return }
            clearValue()
            dependencies.actions.present(.itemEditor(ItemEditorContext(
                repositoryID: repositoryID,
                scope: itemScope,
                mode: .move(item.id)
            )))
        }
    }

    // MARK: - Fill (§7.1, §7.8)

    /// "Already matches GitHub" applies only to a secret GitHub has; an unsynced one is a
    /// pending add.
    var offersFillChoice: Bool {
        isFilling && item?.isSynced == true
    }

    // MARK: - Push on Next Sync (v0.1.2)

    /// Offered while editing a secret that is on GitHub, has a value and has nothing pending.
    var offersPushOnNextSync: Bool {
        guard isEditing, let item else { return false }
        return item.kind == .secret && item.isSynced && item.hasValue && !item.isDeleted
            && (item.syncStatus == .synced || item.syncStatus == .unverifiedShare)
    }

    /// The secret is already marked to be pushed (Revert in the table cancels it).
    var isPushAlreadyRequested: Bool {
        isEditing && item?.syncStatus == .willPush
    }

    /// The save also asks for the push: the toggle is on and the item keeps its name and kind
    /// (a rename or kind change pushes anyway).
    private var requestsPush: Bool {
        guard offersPushOnNextSync, pushOnNextSync, let item else { return false }
        return !isNameChanged && kind == item.kind
    }

    // MARK: - Convert / Move (D11)

    /// False for a value-missing secret → variable (`.valueMissing`) and for scopes the viewer
    /// cannot change.
    func canMove(to kind: ConfigKind) -> Bool {
        guard let item else { return false }
        return !(item.kind == .secret && kind == .variable && !item.hasValue)
    }

    func canMove(to scope: ConfigScope) -> Bool {
        scopeOptions.first { $0.scope == scope }?.isEditable ?? false
    }

    private var isMoveTargetChanged: Bool {
        guard let item else { return false }
        return targetKind != item.kind || targetScope != item.scope
    }

    /// The item's scope title for the move notes (repository items only).
    private func itemScopeTitle(_ item: EditorItemModel) -> String {
        scopeTitle(item.scope ?? .repository)
    }

    /// What Convert/Move does on GitHub, and why a value-missing secret cannot become a
    /// variable.
    var moveNotes: [ConfigEditorNoteModel] {
        guard isMoving, let item else { return [] }
        var notes: [ConfigEditorNoteModel] = []
        if item.kind == .secret, !canMove(to: ConfigKind.variable) {
            notes.append(.info(String(
                localized: "itemEditor.move.valueMissing",
                defaultValue: "\(item.name) has no value in FX Vault, so it can only move as a secret. Fill its value to convert it."
            )))
        }
        guard isMoveTargetChanged else { return notes }
        if item.isSynced {
            notes.append(.info(String(
                localized: "itemEditor.move.synced",
                defaultValue: "The next Sync creates it as a \(targetKind.editorTitle.lowercased()) in \(scopeTitle(targetScope)) and deletes it from \(itemScopeTitle(item)) on GitHub."
            )))
        } else {
            notes.append(.info(String(
                localized: "itemEditor.move.unsynced",
                defaultValue: "It is not on GitHub yet, so it simply moves."
            )))
        }
        return notes
    }

    // MARK: - Save

    var primaryTitle: String {
        switch context.mode {
        case .add:
            String(localized: "itemEditor.save.add", defaultValue: "Add")
        case .edit:
            String(localized: "itemEditor.save.edit", defaultValue: "Save")
        case .fill:
            String(localized: "itemEditor.save.fill", defaultValue: "Fill Value")
        case .move:
            targetKind == item?.kind
                ? String(localized: "itemEditor.save.move", defaultValue: "Move")
                : String(localized: "itemEditor.save.convert", defaultValue: "Convert")
        }
    }

    var canSave: Bool {
        guard canEdit, !isSaving else { return false }
        switch context.mode {
        case .add:
            return isNameValid && isValueValid
        case .edit:
            guard let item, isNameValid, isValueValid else { return false }
            if kind == .variable, item.kind == .secret, !item.hasValue, newValue == nil { return false }
            return isNameChanged || newValue != nil || kind != item.kind || requestsPush
        case .fill:
            return isValueValid
        case .move:
            return isMoveTargetChanged && canMove(to: targetKind) && canMove(to: targetScope)
        }
    }

    /// True when the save turns a secret into a variable (§5.13 confirmation).
    private var convertsSecretToVariable: Bool {
        guard let item, item.kind == .secret else { return false }
        return effectiveKind == .variable
    }

    /// Saves, or asks for the secret → variable confirmation first. Returns true when the sheet
    /// can close.
    func save() -> Bool {
        guard canSave else { return false }
        if convertsSecretToVariable {
            confirmation = secretToVariableConfirmation
            return false
        }
        return perform()
    }

    /// The confirmed secret → variable save.
    func confirm() -> Bool {
        guard confirmation != nil else { return false }
        confirmation = nil
        guard canSave else { return false }
        return perform()
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    private var secretToVariableConfirmation: ItemEditorConfirmationModel {
        let itemName = item?.name ?? normalizedName
        return ItemEditorConfirmationModel(
            title: String(localized: "itemEditor.convert.confirm.title", defaultValue: "Convert \(itemName) to a variable?"),
            message: String(
                localized: "itemEditor.convert.confirm.message",
                defaultValue: "Variable values are stored in plain text on GitHub: anyone who can read the repository and its workflow logs can see this value. If the secret is on GitHub, the next Sync deletes it and creates the variable."
            ),
            confirmTitle: String(localized: "itemEditor.convert.confirm.button", defaultValue: "Convert to Variable")
        )
    }

    private func perform() -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            switch context.mode {
            case .add:
                try add()
            case .edit:
                try edit()
            case .fill:
                try fill()
            case .move:
                try move()
            }
        } catch {
            alert = error.presentation
            return false
        }
        clearValue()
        return true
    }

    private func add() throws(ConfigRepositoryError) {
        let bytes = SecretBytes(utf8: value)
        defer { bytes.wipe() }
        let result = switch context.place {
        case .scope(let repositoryID, let scope):
            try dependencies.config.addItem(repositoryID: repositoryID, scope: scope, kind: kind, name: normalizedName, value: bytes)
        case .folder(let folderID):
            try dependencies.folders.addItem(folderID: folderID, kind: kind, name: normalizedName, value: bytes)
        }
        didStripTrailingNewlines = result.didStripTrailingNewlines
    }

    /// True when the save offers to update the item's linked copies too (a new value).
    var offersLinkedUpdate: Bool {
        isEditing && !linkedCopies.isEmpty && newValue != nil
    }

    func setLinkedCopy(_ id: ConfigItemID, included: Bool) {
        if included {
            linkedSelection.insert(id)
        } else {
            linkedSelection.remove(id)
        }
    }

    /// Rename, then the value, then the kind (an item not yet on GitHub), then Push on Next
    /// Sync, then the checked linked copies (v0.4.1): each step validated up front by
    /// ``canSave``.
    private func edit() throws(ConfigRepositoryError) {
        guard let item else { throw .itemNotFound }
        let config = dependencies.config
        let shouldRequestPush = requestsPush
        let linkedTargets = offersLinkedUpdate
            ? linkedCopies.filter { $0.isEditable && linkedSelection.contains($0.itemID) }.map(\.itemID)
            : []
        if case .folder = context.place {
            // One transaction for name, kind and value; nothing is pending (v0.7.0).
            let bytes = newValue.map { SecretBytes(utf8: $0) }
            defer { bytes?.wipe() }
            didStripTrailingNewlines = try dependencies.folders.editItem(item.id, name: normalizedName, kind: kind, value: bytes)
                .didStripTrailingNewlines
            if !linkedTargets.isEmpty {
                try config.updateLinkedCopies(from: item.id, to: linkedTargets)
            }
            return
        }
        var id = item.id
        if isNameChanged {
            id = try config.renameItem(id, to: normalizedName)
        }
        if let newValue {
            let bytes = SecretBytes(utf8: newValue)
            defer { bytes.wipe() }
            didStripTrailingNewlines = try config.editValue(id, value: bytes).didStripTrailingNewlines
        }
        if kind != item.kind {
            id = try config.moveItem(id, toKind: kind, scope: item.scope ?? scope)
        }
        if shouldRequestPush {
            try config.requestPush(id)
        }
        if !linkedTargets.isEmpty {
            try config.updateLinkedCopies(from: id, to: linkedTargets)
        }
    }

    private func fill() throws(ConfigRepositoryError) {
        guard let item else { throw .itemNotFound }
        let bytes = SecretBytes(utf8: value)
        defer { bytes.wipe() }
        let result = try dependencies.config.fillValue(
            item.id,
            value: bytes,
            pushOnNextSync: !fillMatchesGitHub
        )
        didStripTrailingNewlines = result.didStripTrailingNewlines
    }

    private func move() throws(ConfigRepositoryError) {
        guard let item else { throw .itemNotFound }
        try dependencies.config.moveItem(item.id, toKind: targetKind, scope: targetScope)
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
        isCurrentValueLoaded = false
    }

    func vaultDidLock() {
        clearValue()
        confirmation = nil
        linkedCopies = []
        linkedSelection = []
    }

    // MARK: - Helpers

    static var repositoryTitle: String {
        String(localized: "main.scopes.repository", defaultValue: "Repository")
    }

    static func title(of summary: ConfigScopeSummaryModel) -> String {
        summary.environment?.name ?? repositoryTitle
    }

    /// Uppercases ASCII letters only: GitHub stores names in uppercase, and non-ASCII letters
    /// must stay visible so the validator can reject them (`ß` would otherwise become `SS`).
    static func uppercasingASCII(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            result += character.isASCII ? character.uppercased() : String(character)
        }
        return result
    }
}
