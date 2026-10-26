import Foundation
import Observation
import VaultCore
import VaultData

/// How a value cell shows its value (§5.11, §10 Column 3).
enum ConfigValueDisplayModel: Hashable {
    /// A secret, masked until revealed.
    case masked
    /// A secret revealed by the eye toggle (re-masked on resign active and after 30 s).
    case revealed(String)
    /// A variable, shown in plaintext.
    case plain(String)
    /// A secret whose value is not in the vault (imported from GitHub, §7.8).
    case missing
}

/// One row of the Secrets | Variables table. Values are not part of the row; the cell asks the
/// view model (``RepoDetailViewModel/display(for:)``).
struct ConfigRowModel: Identifiable, Hashable {
    let id: ConfigItemID
    let name: String
    let kind: ConfigKind
    let hasValue: Bool
    let isDeleted: Bool
    let isSynced: Bool
    let updatedAt: Date
    let status: ConfigSyncStatus
    /// "Renamed from OLD_NAME" while a rename is pending.
    let syncedName: String?
    /// How many places share this item's link, this one included (v0.4.1); 0 when not linked.
    let linkCount: Int
    /// The share file whose import holds this row out of Sync (v0.9.0, P8); nil when not held.
    var heldBy: SharePackageID?

    init(_ item: ConfigItemModel) {
        id = item.id
        name = item.name
        kind = item.kind
        hasValue = item.hasValue
        isDeleted = item.isDeleted
        isSynced = item.isSynced
        updatedAt = item.updatedAt
        status = item.syncStatus
        syncedName = item.syncedName == item.name ? nil : item.syncedName
        linkCount = item.isLinked ? item.linkCount : 0
        heldBy = item.heldBy
    }

    /// True when a share file holds this row (the Held chip, v0.9.0).
    var isHeld: Bool {
        heldBy != nil && !isDeleted
    }

    /// True when the Linked chip shows (another live place shares the link).
    var isLinked: Bool {
        linkCount > 1
    }

    /// True when Revert has something to undo (a synced item with a local change).
    var canRevert: Bool {
        isSynced && status != .synced && status != .unverifiedShare
    }

    /// "Push on Next Sync" is offered for a secret on GitHub with a value and nothing pending.
    /// Variables are compared by value, so they never need it. On a held row (v0.9.0) it
    /// releases the hold instead, so the next Sync sends it.
    var canPushOnNextSync: Bool {
        isHeld || (kind == .secret && hasValue && isSynced && !isDeleted && (status == .synced || status == .unverifiedShare))
    }
}

/// The rows waiting for the "Delete?" confirmation: one row, or a multi-selection (v0.4.0).
struct ConfigDeletionModel: Hashable {
    let rows: [ConfigRowModel]

    /// The rows on GitHub: the next Sync deletes them there after its deletion review.
    var syncedRows: [ConfigRowModel] {
        rows.filter(\.isSynced)
    }

    /// The rows never synced: they are removed from the vault at once.
    var unsyncedCount: Int {
        rows.count - syncedRows.count
    }
}

/// A copy into another scope waiting for "Replace or keep?": the target already has `conflicts`.
struct ItemCopyRequestModel: Hashable {
    let ids: [ConfigItemID]
    let target: ItemCopyTargetModel
    let conflicts: [String]

    var targetTitle: String {
        target.title
    }
}

/// A place Copy To offers (a scope of a vault repository or, v0.7.0, a folder), and whether
/// items can be added there.
struct ItemCopyTargetModel: Hashable, Identifiable {
    let place: ItemPlaceModel
    /// "staging" in the same repository, "owner/name · staging" in another one, or a folder's
    /// name.
    let title: String
    let isEditable: Bool

    init(place: ItemPlaceModel, title: String, isEditable: Bool) {
        self.place = place
        self.title = title
        self.isEditable = isEditable
    }

    init(repositoryID: RepoID, scope: ConfigScope, title: String, isEditable: Bool) {
        self.init(place: .scope(repositoryID: repositoryID, scope: scope), title: title, isEditable: isEditable)
    }

    var id: ItemPlaceModel {
        place
    }

    /// The repository of a scope target; nil for a folder.
    var repositoryID: RepoID? {
        place.repositoryID
    }

    /// The scope of a scope target; nil for a folder.
    var scope: ConfigScope? {
        if case .scope(_, let scope) = place { return scope }
        return nil
    }
}

/// Column 3 (§10; boards Main2-Repository, Main2-Actions): the header (the scope's name, "kind ·
/// parent · counts", Refreshing… or the drift line, ⋯ More with Clone, Refresh and Deployment
/// Branches…), the read-only explanation and one table with the Secrets | Variables pill and
/// the row actions.
///
/// Values: a secret is decrypted only while revealed or copied, and every revealed value is
/// masked again after `Timeouts.revealRemask`, when FX Vault resigns active, when the scope
/// changes and on lock. Variables are shown in plaintext (§10), decrypted for the visible scope
/// only and dropped on lock.
@Observable
final class RepoDetailViewModel: LockObserving {
    let repositoryID: RepoID
    private(set) var scope: ConfigScope = .repository
    var kind: ConfigKind = .secret {
        didSet {
            if kind != oldValue {
                selection.removeAll()
            }
        }
    }
    private(set) var items: [ConfigItemModel] = []
    /// Revealed secrets and decrypted variables (shared with folders, v0.7.0).
    let values: ConfigValueRevealer
    var selection: Set<ConfigItemID> = []
    private(set) var driftReport: DriftReportModel?
    /// Why the last drift check failed (shown as a small note); nil otherwise.
    private(set) var driftError: ErrorPresentationModel?
    private(set) var isRefreshing = false
    var alert: ErrorPresentationModel?
    /// A short confirmation ("Copied API_TOKEN. The clipboard clears in 30 seconds.").
    private(set) var notice: String?
    /// The items waiting for the "Delete?" confirmation.
    var pendingDeletion: ConfigDeletionModel?
    /// Copy and paste with "Replace or keep?" (shared with folders, v0.7.0).
    let copyFlow: ItemCopyFlow
    /// The row whose linked copies popover is open (v0.4.1).
    var linkedPopoverRowID: ConfigItemID? {
        didSet {
            if linkedPopoverRowID == nil {
                linkedCopies = []
            }
        }
    }
    /// The other places of ``linkedPopoverRowID``, loaded when the popover opens.
    private(set) var linkedCopies: [LinkedCopyModel] = []

    @ObservationIgnored private(set) var driftTask: Task<Void, Never>?
    /// A drift check was asked for while offline and skipped: the reconnect check re-lists.
    @ObservationIgnored private var missedDriftCheckOffline = false
    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let repositoryProvider: () -> RepoModel?
    @ObservationIgnored private let scopeProvider: (ConfigScope) -> ConfigScopeSummaryModel?
    @ObservationIgnored private let tasks = TaskBag()
    /// The senders of the share files that hold rows here, for the Held chip (v0.9.0).
    @ObservationIgnored private lazy var heldSenders = HeldSenderNames { [dependencies] in dependencies.shareHolds }

    /// - Parameters:
    ///   - repository: the live vault row.
    ///   - scopeSummary: the live summary of a scope (pending dot, value-missing count, the
    ///     environment row with its branch policy).
    init(
        repositoryID: RepoID,
        dependencies: FeatureDependencies,
        repository: @escaping () -> RepoModel?,
        scopeSummary: @escaping (ConfigScope) -> ConfigScopeSummaryModel?
    ) {
        self.repositoryID = repositoryID
        self.dependencies = dependencies
        values = ConfigValueRevealer(config: dependencies.config, clock: dependencies.clock)
        copyFlow = ItemCopyFlow(dependencies: dependencies)
        repositoryProvider = repository
        scopeProvider = scopeSummary
        dependencies.actions.addLockObserver(self)
        observeItems()
    }

    // MARK: - Header

    var repository: RepoModel? {
        repositoryProvider()
    }

    var scopeSummary: ConfigScopeSummaryModel? {
        scopeProvider(scope)
    }

    var capability: RepoCapabilityModel? {
        repository?.capability
    }

    /// Items of the selected scope can be added, edited, deleted and moved.
    var canEdit: Bool {
        guard let capability, scopeSummary?.isDeleted != true else { return false }
        return capability.canEditItems(at: scope.level)
    }

    /// Why this scope is read-only, or nil when it can be changed.
    var readOnlyReason: RepoCapabilityModel.ReadOnlyReason? {
        capability?.readOnlyReason(for: scope.level)
    }

    /// The header's name: the environment's, or the repository's for the repository scope.
    var headerTitle: String {
        if scope.level == .environment, let summary = scopeSummary {
            return summary.title
        }
        return repository?.name ?? ""
    }

    /// "Environment · api-service · 6 secrets · 2 variables · 1 without value", or "Repository ·
    /// example-org · Private · …" for the repository scope (1.0 D6c3; board Main2-Repository).
    var headerSubline: String {
        let counts = PlaceCopy.counts(
            secrets: count(of: .secret),
            variables: count(of: .variable),
            withoutValue: items.lazy.filter { $0.kind == .secret && !$0.isDeleted && !$0.hasValue }.count
        )
        guard let repository else { return counts }
        if scope.level == .environment {
            return PlaceCopy.subline([PlaceCopy.environment, repository.name, counts])
        }
        return PlaceCopy.subline([
            PlaceCopy.repository,
            repository.ownerLogin,
            repository.visibility.localizedTitle,
            repository.existsOnGitHub ? nil : PlaceCopy.createdByNextSync,
            counts,
        ])
    }

    /// The environment's deployment branch policy; nil for the repository scope.
    var branchPolicy: DeploymentBranchPolicyModel? {
        scopeSummary?.environment?.branchPolicy
    }

    /// The plan note (§10): environment features on private repositories depend on the plan.
    var showsPlanNote: Bool {
        scope.level == .environment && repository?.visibility.isPrivate == true
    }

    /// False while the Mac has no internet connection: Clone, Refresh and drift checks wait
    /// (the main window re-runs the drift check when the connection returns).
    var isOnline: Bool {
        dependencies.connectivity.isOnline
    }

    var canClone: Bool {
        guard let repository else { return false }
        return repository.existsOnGitHub && dependencies.actions.isGitHubReady() && isOnline
    }

    var canRefresh: Bool {
        guard let repository else { return false }
        return repository.existsOnGitHub && dependencies.actions.isGitHubReady() && isOnline && !isRefreshing
    }

    /// Drift checks need the repository on GitHub, gh and the internet.
    private var canCheckDrift: Bool {
        guard let repository else { return false }
        return repository.existsOnGitHub && dependencies.actions.isGitHubReady() && isOnline
    }

    /// Remembers a drift check skipped because the Mac was offline: the reconnect check re-lists.
    private func noteSkippedDriftCheck() {
        if !isOnline {
            missedDriftCheckOffline = true
        }
    }

    // MARK: - Table

    var rows: [ConfigRowModel] {
        items
            .filter { $0.kind == kind }
            .sorted { $0.name < $1.name }
            .map(ConfigRowModel.init)
    }

    func count(of kind: ConfigKind) -> Int {
        items.lazy.filter { $0.kind == kind && !$0.isDeleted }.count
    }

    func display(for row: ConfigRowModel) -> ConfigValueDisplayModel {
        values.display(for: row)
    }

    /// A repository scope shows each row's sync status.
    var showsSyncStatus: Bool {
        true
    }

    var revealedValues: [ConfigItemID: String] {
        values.revealedValues
    }

    var variableValues: [ConfigItemID: String] {
        values.variableValues
    }

    /// The scheduled re-mask of each revealed value (internal so tests can await it).
    var remaskTasks: [ConfigItemID: Task<Void, Never>] {
        values.remaskTasks
    }

    /// A copy waiting for "Replace or keep?".
    var pendingCopy: ItemCopyRequestModel? {
        get { copyFlow.pendingCopy }
        set { copyFlow.pendingCopy = newValue }
    }

    // MARK: - Selection (v0.4.0)

    /// The selected rows of the visible kind, in table order.
    var selectedRows: [ConfigRowModel] {
        rows(for: selection)
    }

    /// The rows of `ids` in table order (a context menu's rows can differ from the selection).
    func rows(for ids: Set<ConfigItemID>) -> [ConfigRowModel] {
        rows.filter { ids.contains($0.id) }
    }

    func clearSelection() {
        selection.removeAll()
    }

    // MARK: - Copy and paste (v0.4.0; any repository and linked since v0.4.1)

    /// Copy To: the repository's other scopes (``copyTargets``).
    var scopeCopyTargets: [ItemCopyTargetModel] {
        copyTargets
    }

    /// Copy To › Folder (v0.7.0): every folder of the vault.
    var folderCopyTargets: [ItemCopyTargetModel] {
        dependencies.folderCopyTargets()
    }

    /// Copy To › Destinations (v0.8.0): this repository's destinations.
    var destinationCopyTargets: [ItemCopyTargetModel] {
        dependencies.destinationCopyTargets(repositoryID: repositoryID)
    }

    /// The repository's other scopes, where Copy To copies; those the account may not change
    /// are listed disabled. Other repositories are offered by "Other Repository…".
    var copyTargets: [ItemCopyTargetModel] {
        let summaries = (try? dependencies.config.scopes(repositoryID: repositoryID)) ?? []
        return summaries
            .filter { $0.scope != scope && !$0.isDeleted }
            .map { summary in
                ItemCopyTargetModel(
                    repositoryID: repositoryID,
                    scope: summary.scope,
                    title: summary.title,
                    isEditable: capability?.canEditItems(at: summary.scope.level) == true
                )
            }
    }

    /// ⌘C on the table: the selected rows go to the app's item clipboard and their names to the
    /// pasteboard. ⌘V in any other scope of any repository pastes them as linked copies.
    func copySelection() {
        let rows = selectedRows.filter { !$0.isDeleted }
        guard let first = rows.first else { return }
        dependencies.clipboard.copyItems(CopiedItemsModel(
            ids: rows.map(\.id),
            names: rows.map(\.name),
            source: .scope(repositoryID: repositoryID, scope: scope)
        ))
        notice = rows.count == 1
            ? String(
                localized: "main.detail.copiedItem.notice.linked",
                defaultValue: "Copied \(first.name). Open another scope or repository and paste it with ⌘V: the copy stays linked to this item."
            )
            : String(
                localized: "main.detail.copiedItems.notice.linked",
                defaultValue: "Copied \(rows.count) items. Open another scope or repository and paste them with ⌘V: the copies stay linked to these items."
            )
    }

    /// Copy To from the context menu or the selection bar.
    func copy(_ rows: [ConfigRowModel], to target: ItemCopyTargetModel) {
        requestCopy(ids: rows.filter { !$0.isDeleted }.map(\.id), to: target)
    }

    /// Copy To › Other Repository…: the searchable list of every repository of the vault.
    func copyToOtherRepository(_ rows: [ConfigRowModel]) {
        let ids = rows.filter { !$0.isDeleted }.map(\.id)
        guard !ids.isEmpty else { return }
        dependencies.actions.present(.copyToRepository(CopyToRepositoryContext(
            itemIDs: ids,
            source: .scope(repositoryID: repositoryID, scope: scope)
        )))
    }

    func confirmCopy(replacing: Bool) {
        do {
            if let (request, result) = try copyFlow.confirm(replacing: replacing) {
                notice = result.notice(target: request.target.title)
            }
        } catch {
            alert = error.presentation
        }
    }

    /// ⌘V while the pasteboard still holds names FX Vault copied: their items, not the text.
    private func pasteCopiedItems() {
        guard let copied = dependencies.clipboard.itemsToPaste else {
            notice = String(
                localized: "main.detail.paste.expired",
                defaultValue: "The copied items are no longer available (FX Vault was locked). Select them and press ⌘C again."
            )
            return
        }
        guard copied.source != .scope(repositoryID: repositoryID, scope: scope) else {
            notice = String(
                localized: "main.detail.paste.sameScope.linked",
                defaultValue: "These items are already in this scope. Open another scope or repository to paste them."
            )
            return
        }
        requestCopy(ids: copied.ids, to: ItemCopyTargetModel(
            repositoryID: repositoryID,
            scope: scope,
            title: scopeSummary?.title ?? "",
            isEditable: canEdit
        ))
    }

    /// Asks "Replace or keep?" when the target already has some of the names, otherwise copies.
    private func requestCopy(ids: [ConfigItemID], to target: ItemCopyTargetModel) {
        do {
            if let result = try copyFlow.request(ids, to: target) {
                notice = result.notice(target: target.title)
            }
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - Linked copies (v0.4.1)

    /// Opens the linked copies popover of `row` (its chip, or Show Linked Copies in its menu).
    func showLinkedCopies(of row: ConfigRowModel) {
        do {
            linkedCopies = try dependencies.config.linkedCopies(of: row.id)
            linkedPopoverRowID = row.id
        } catch {
            alert = error.presentation
        }
    }

    /// Shows a linked copy's repository and scope, or its folder (v0.7.0).
    func openLinkedCopy(_ copy: LinkedCopyModel) {
        linkedPopoverRowID = nil
        dependencies.actions.openPlace(copy.itemPlace)
    }

    /// Takes `row` out of its link group; its copies stay where they are.
    func unlink(_ row: ConfigRowModel) {
        linkedPopoverRowID = nil
        do {
            try dependencies.config.unlink(row.id)
            notice = String(
                localized: "main.detail.unlinked",
                defaultValue: "\(row.name) is no longer linked. The copies stay where they are."
            )
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - Scope

    /// Shows another scope of the repository: masks everything and observes its items.
    func select(scope: ConfigScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        selection.removeAll()
        remaskAll()
        values.clearVariables()
        items = []
        observeItems()
    }

    private func observeItems() {
        let stream = dependencies.config.observeItems(repositoryID: repositoryID, scope: scope)
        tasks.set("items", Task { [weak self] in
            do {
                for try await items in stream {
                    self?.apply(items)
                }
            } catch {
                AppLog.ui.error("Item observation ended")
            }
        })
    }

    /// Applies a new snapshot of the scope's items: revealed rows that are gone are masked and the
    /// variables decrypted for plaintext display (a locked vault shows them masked).
    func apply(_ items: [ConfigItemModel]) {
        self.items = items
        values.follow(
            liveIDs: Set(items.map(\.id)),
            variableIDs: items.filter { $0.kind == .variable && $0.hasValue }.map(\.id)
        )
    }

    // MARK: - Reveal and copy (§5.9, §5.11)

    func isRevealed(_ id: ConfigItemID) -> Bool {
        values.isRevealed(id)
    }

    func toggleReveal(_ id: ConfigItemID) {
        if isRevealed(id) {
            hide(id)
        } else {
            reveal(id)
        }
    }

    /// Decrypts one secret for display and schedules its re-mask.
    func reveal(_ id: ConfigItemID) {
        do {
            try values.reveal(id)
        } catch {
            alert = error.presentation
        }
    }

    func hide(_ id: ConfigItemID) {
        values.hide(id)
    }

    /// Masks every revealed value (resign active, scope change, lock).
    func remaskAll() {
        values.remaskAll()
    }

    /// Copies the value through `ClipboardManager` (concealed, cleared after 30 s).
    func copy(_ id: ConfigItemID) {
        do {
            try dependencies.copyValue(of: id)
            let name = items.first { $0.id == id }?.name ?? ""
            notice = String(
                localized: "main.detail.copied",
                defaultValue: "Copied \(name). The clipboard clears in \(dependencies.clipboard.clearDelay.wholeSeconds) seconds."
            )
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - Row actions

    func add() {
        guard canEdit else { return }
        present(.add(kind))
    }

    // MARK: - Import and paste (v0.1.1)

    /// "Paste Multiple…": the import sheet in paste mode, focused, rows defaulting to the tab's
    /// kind and the target defaulting to the open scope.
    func pasteMultiple() {
        presentImport(.pasteEditor)
    }

    /// Import .env… from ⋯ More: the file chooser, rows defaulting to the tab's kind.
    func importEnvFile() {
        presentImport(.chooser)
    }

    /// The ⌘V validator: the providers while this scope can be edited, nil (Paste disabled)
    /// otherwise.
    func validatePaste(_ providers: [NSItemProvider]) -> [NSItemProvider]? {
        canEdit ? providers : nil
    }

    /// ⌘V in the detail column (`onPasteCommand`, a user action: the pasteboard is never read in the
    /// background). Reads the pasted plain text from the providers and opens the import preview
    /// prefilled with it, even for a single KEY=value line. Nothing is logged.
    func handlePaste(_ providers: [NSItemProvider]) async {
        guard canEdit else { return }
        if dependencies.clipboard.holdsItemNames {
            pasteCopiedItems()
            return
        }
        guard let text = await Self.plainText(from: providers) else { return }
        paste(text)
    }

    /// Opens the import preview prefilled with `text` (whitespace-only text is ignored).
    func paste(_ text: String) {
        guard canEdit, !text.allSatisfy(\.isWhitespace) else { return }
        presentImport(.pasted(EnvPasteBuffer(SecretBytes(utf8: text))))
    }

    private func presentImport(_ start: EnvImportContext.Start) {
        guard canEdit else { return }
        dependencies.actions.present(.envImport(EnvImportContext(
            repositoryID: repositoryID,
            scope: scope,
            defaultKind: kind,
            start: start
        )))
    }

    /// The first provider's plain text, or nil.
    private static func plainText(from providers: [NSItemProvider]) async -> String? {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { @Sendable text, _ in
                continuation.resume(returning: text)
            }
        }
    }

    /// Edit, or Fill Value for a value-missing secret (§7.8).
    func edit(_ row: ConfigRowModel) {
        guard canEdit, !row.isDeleted else { return }
        present(row.hasValue ? .edit(row.id) : .fill(row.id))
    }

    func move(_ row: ConfigRowModel) {
        guard canEdit, !row.isDeleted else { return }
        present(.move(row.id))
    }

    func revert(_ row: ConfigRowModel) {
        do {
            try dependencies.config.revertItem(row.id)
        } catch {
            alert = error.presentation
        }
    }

    /// "Push on Next Sync" (v0.1.2): the next Sync re-sends the secret's value even if it did not
    /// change, so GitHub matches the vault. The row shows "Will push" until then; Revert undoes it.
    func pushOnNextSync(_ row: ConfigRowModel) {
        guard canEdit, row.canPushOnNextSync else { return }
        if row.isHeld {
            releaseHolds([row])
            return
        }
        do {
            try dependencies.config.requestPush(row.id)
            notice = String(
                localized: "main.detail.pushOnNextSync.notice",
                defaultValue: "The next Sync pushes \(row.name) to GitHub. Revert cancels it."
            )
        } catch {
            alert = error.presentation
        }
    }

    func requestDeletion(_ row: ConfigRowModel) {
        requestDeletion(of: [row])
    }

    /// Delete… for one row or a multi-selection: rows on GitHub need the confirmation (the next
    /// Sync deletes them there after its review); rows never synced are removed at once.
    func requestDeletion(of rows: [ConfigRowModel]) {
        let deletable = rows.filter { !$0.isDeleted }
        guard canEdit, !deletable.isEmpty else { return }
        if deletable.contains(where: \.isSynced) {
            pendingDeletion = ConfigDeletionModel(rows: deletable)
        } else {
            delete(deletable)
        }
    }

    /// ⌫ on the table: Delete… for the selected rows.
    func deleteSelection() {
        requestDeletion(of: selectedRows)
    }

    func confirmDeletion() {
        guard let deletion = pendingDeletion else { return }
        pendingDeletion = nil
        delete(deletion.rows)
    }

    /// One transaction for all of them.
    private func delete(_ rows: [ConfigRowModel]) {
        let ids = rows.map(\.id)
        ids.forEach(hide)
        do {
            try dependencies.config.deleteItems(ids, repositoryID: repositoryID)
            selection.subtract(ids)
            if rows.count > 1 {
                let onGitHub = rows.filter(\.isSynced).count
                notice = onGitHub > 0
                    ? String(
                        localized: "main.detail.deleted.notice",
                        defaultValue: "Deleted \(rows.count) items. The next Sync deletes \(onGitHub) of them on GitHub after you confirm. Revert undoes it until then."
                    )
                    : String(localized: "main.detail.removed.notice", defaultValue: "Removed \(rows.count) items that were never synced.")
            }
        } catch {
            alert = error.presentation
        }
    }

    /// Revert for a multi-selection: the rows with a local change, in one transaction.
    func revert(_ rows: [ConfigRowModel]) {
        let ids = rows.filter(\.canRevert).map(\.id)
        guard !ids.isEmpty else { return }
        do {
            try dependencies.config.revertItems(ids, repositoryID: repositoryID)
            selection.removeAll()
            notice = ids.count == 1
                ? String(localized: "main.detail.reverted.one.notice", defaultValue: "Reverted 1 item to what GitHub has.")
                : String(localized: "main.detail.reverted.notice", defaultValue: "Reverted \(ids.count) items to what GitHub has.")
        } catch {
            alert = error.presentation
        }
    }

    /// Push on Next Sync for a multi-selection: the secrets it applies to, in one transaction.
    func pushOnNextSync(_ rows: [ConfigRowModel]) {
        let pushable = rows.filter(\.canPushOnNextSync)
        guard canEdit, !pushable.isEmpty else { return }
        let held = pushable.filter(\.isHeld)
        if !held.isEmpty {
            releaseHolds(held)
        }
        let ids = pushable.filter { !$0.isHeld }.map(\.id)
        guard !ids.isEmpty else { return }
        do {
            try dependencies.config.requestPush(ids, repositoryID: repositoryID)
            selection.removeAll()
            notice = ids.count == 1
                ? String(localized: "main.detail.pushOnNextSync.one.notice", defaultValue: "The next Sync pushes 1 secret to GitHub. Revert cancels it.")
                : String(
                    localized: "main.detail.pushOnNextSync.several.notice",
                    defaultValue: "The next Sync pushes \(ids.count) secrets to GitHub. Revert cancels it."
                )
        } catch {
            alert = error.presentation
        }
    }

    /// Push on Next Sync on held rows (v0.9.0): releases their holds and nothing else, so the
    /// next Sync sends them as ordinary pending changes.
    private func releaseHolds(_ rows: [ConfigRowModel]) {
        do {
            let released = try dependencies.shareHolds.releaseHold(itemIDs: rows.map(\.id))
            selection.removeAll()
            notice = HeldShareCopy.released(name: rows.count == 1 ? rows.first?.name : nil, count: released)
        } catch {
            alert = error.presentation
        }
    }

    /// The Held chip's tooltip, naming the share file's sender when it is known.
    func heldHelp(for row: ConfigRowModel) -> String {
        HeldShareCopy.chipHelp(sender: row.heldBy.flatMap { heldSenders.name(of: $0) })
    }

    private func present(_ mode: ItemEditorContext.Mode) {
        dependencies.actions.present(.itemEditor(ItemEditorContext(repositoryID: repositoryID, scope: scope, mode: mode)))
    }

    func editBranchPolicy() {
        guard canEdit, let environment = scopeSummary?.environment else { return }
        dependencies.actions.present(.environmentSettings(
            EnvironmentContext(repositoryID: repositoryID, environmentID: environment.id)
        ))
    }

    // MARK: - GitHub (refresh and drift, §7.7)

    /// The drift check when the repository opens (debounced by `DriftRepository`).
    func checkDriftOnOpen() {
        guard let repository, !repository.isUnavailable else { return }
        guard canCheckDrift else {
            noteSkippedDriftCheck()
            return
        }
        missedDriftCheckOffline = false
        let drift = dependencies.drift
        let reachability = dependencies.gitHubReachability
        let id = repositoryID
        driftTask?.cancel()
        driftTask = Task { [weak self] in
            do {
                let report = try await drift.detectOnOpen(id)
                reachability.recordSuccess()
                self?.driftReport = report
                self?.driftError = nil
            } catch {
                reachability.record(error)
                self?.driftError = error.presentation
            }
        }
    }

    /// **Refresh**: re-reads the repository's metadata (permission, archived, visibility) and
    /// runs the drift check again.
    func refresh() async {
        guard canRefresh else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await dependencies.catalog.refreshRepository(repositoryID)
            driftReport = try await dependencies.drift.refresh(repositoryID)
            driftError = nil
            dependencies.gitHubReachability.recordSuccess()
        } catch {
            dependencies.gitHubReachability.record(error)
            alert = error.presentation
        }
    }

    /// Re-runs the drift check after a feature resolved findings or synced, and from the
    /// banner's Retry.
    func refreshDrift() async {
        await checkDrift(debounced: false)
    }

    /// The internet connection came back: a full re-list only when the last check failed, never
    /// ran, or was skipped while offline; otherwise the debounced check, so a flapping
    /// connection does not re-list the repository on every return.
    func checkDriftAfterReconnect() async {
        await checkDrift(debounced: driftReport != nil && driftError == nil && !missedDriftCheckOffline)
    }

    private func checkDrift(debounced: Bool) async {
        guard canCheckDrift else {
            noteSkippedDriftCheck()
            return
        }
        missedDriftCheckOffline = false
        do {
            driftReport = debounced
                ? try await dependencies.drift.detectOnOpen(repositoryID)
                : try await dependencies.drift.refresh(repositoryID)
            driftError = nil
            dependencies.gitHubReachability.recordSuccess()
        } catch {
            dependencies.gitHubReachability.record(error)
            driftError = error.presentation
        }
    }

    func reviewDrift() {
        dependencies.actions.present(.driftReview(DriftReviewContext(repositoryID: repositoryID)))
    }

    // MARK: - LockObserving

    func vaultDidLock() {
        remaskAll()
        values.clearVariables()
        driftTask?.cancel()
        driftReport = nil
        pendingDeletion = nil
        pendingCopy = nil
        linkedPopoverRowID = nil
    }
}

extension RepoDetailViewModel: ConfigTableModel {}

extension ItemCopyResultModel {
    /// "Copied 3 items to staging." with what was kept or left out.
    func notice(target: String) -> String {
        let copied = added + replaced
        let summary = switch copied {
        case 0: String(localized: "main.detail.copy.none", defaultValue: "Nothing was copied to \(target).")
        case 1: String(localized: "main.detail.copy.one", defaultValue: "Copied 1 item to \(target).")
        default: String(localized: "main.detail.copy.several", defaultValue: "Copied \(copied) items to \(target).")
        }
        var parts = [summary]
        if kept > 0 {
            parts.append(String(localized: "main.detail.copy.kept", defaultValue: "Kept \(kept) that \(target) already had."))
        }
        if !withoutValue.isEmpty {
            let names = withoutValue.formatted(.list(type: .and))
            parts.append(String(
                localized: "main.detail.copy.withoutValue",
                defaultValue: "Not copied, no value in FX Vault (GitHub never returns secret values): \(names). Fill them first."
            ))
        }
        return parts.joined(separator: " ")
    }
}
