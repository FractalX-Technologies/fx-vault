import Foundation
import Observation
import VaultCore
import VaultData

/// Column 3 for a runtime destination (v0.8.0, tasks/todo.md R7): the destination's name,
/// provider, stage and rules, the Secrets | Variables pill (Secrets only where the provider holds
/// secrets only) and the table with the Status column, since destination changes wait for the
/// next Sync like repository changes.
///
/// Values follow the repository rules (``ConfigValueRevealer``). ⌘C copies the selected items
/// for ⌘V in a scope, folder or destination; Copy To lists the repository's scopes, the folders and
/// the other destinations. Every copy stays linked to its source.
@Observable
final class DestinationDetailViewModel: LockObserving {
    let destinationID: DestinationID
    /// nil: a Key Vault of its own (1.0).
    let repositoryID: RepoID?
    var kind: ConfigKind = .secret {
        didSet {
            if kind != oldValue {
                selection.removeAll()
            }
        }
    }
    private(set) var items: [DestinationItemModel] = []
    let values: ConfigValueRevealer
    let copyFlow: ItemCopyFlow
    var selection: Set<ConfigItemID> = []
    var alert: ErrorPresentationModel?
    private(set) var notice: String?
    /// The rows waiting for the "Delete?" confirmation.
    var pendingDeletion: [ConfigRowModel]?
    var linkedPopoverRowID: ConfigItemID? {
        didSet {
            if linkedPopoverRowID == nil {
                linkedCopies = []
            }
        }
    }
    private(set) var linkedCopies: [LinkedCopyModel] = []
    /// Refresh's findings (R6), shown as the banner; nil before the first Refresh.
    private(set) var refresh: DestinationRefreshPresentationModel?
    private(set) var isRefreshing = false

    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let destinationProvider: () -> DestinationModel?
    @ObservationIgnored private let tasks = TaskBag()
    /// The senders of the share files that hold rows here, for the Held chip (v0.9.0).
    @ObservationIgnored private lazy var heldSenders = HeldSenderNames { [dependencies] in dependencies.shareHolds }

    /// - Parameter destination: the live destination row (its counts follow its sidebar row).
    init(destination: DestinationModel, dependencies: FeatureDependencies, live: @escaping () -> DestinationModel?) {
        destinationID = destination.id
        repositoryID = destination.repositoryID
        self.dependencies = dependencies
        destinationProvider = live
        values = ConfigValueRevealer(config: dependencies.config, clock: dependencies.clock)
        copyFlow = ItemCopyFlow(dependencies: dependencies)
        dependencies.actions.addLockObserver(self)
        observeItems()
    }

    var destination: DestinationModel? {
        destinationProvider()
    }

    /// "Key Vault · 32 secrets" (board KV-Place; its subscription arrives with 1g); a runtime
    /// destination adds "Runtime" and its stage.
    var subline: String {
        guard let destination else { return "" }
        let counts = PlaceCopy.counts(secrets: count(of: .secret), variables: nil)
        guard destination.repositoryID != nil else {
            return PlaceCopy.subline([destination.provider.shortTitle, counts])
        }
        return PlaceCopy.subline([
            destination.provider.shortTitle,
            DestinationCopy.runtimeSection,
            destination.stage ?? DestinationCopy.noStage,
            counts,
        ])
    }

    private var place: ItemPlaceModel {
        .destination(destinationID)
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

    /// A destination's items can change while it exists; the provider is reached only by Sync.
    var canEdit: Bool {
        destination != nil
    }

    var showsSyncStatus: Bool {
        true
    }

    func display(for row: ConfigRowModel) -> ConfigValueDisplayModel {
        values.display(for: row)
    }

    func rows(for ids: Set<ConfigItemID>) -> [ConfigRowModel] {
        rows.filter { ids.contains($0.id) }
    }

    var selectedRows: [ConfigRowModel] {
        rows(for: selection)
    }

    func clearSelection() {
        selection.removeAll()
    }

    func item(_ id: ConfigItemID) -> DestinationItemModel? {
        items.first { $0.id == id }
    }

    private func observeItems() {
        let stream = dependencies.destinations.observeItems(destinationID: destinationID)
        tasks.set("items", Task { [weak self] in
            do {
                for try await items in stream {
                    self?.apply(items)
                }
            } catch {
                AppLog.ui.error("Destination item observation ended")
            }
        })
    }

    func apply(_ items: [DestinationItemModel]) {
        self.items = items
        values.follow(liveIDs: Set(items.map(\.id)), variableIDs: items.filter { $0.kind == .variable }.map(\.id))
        // Key Vault holds secrets only (R3): the table never shows variables.
        kind = .secret
    }

    // MARK: - Reveal and copy

    func isRevealed(_ id: ConfigItemID) -> Bool {
        values.isRevealed(id)
    }

    func toggleReveal(_ id: ConfigItemID) {
        if values.isRevealed(id) {
            values.hide(id)
            return
        }
        do {
            try values.reveal(id)
        } catch {
            alert = error.presentation
        }
    }

    func remaskAll() {
        values.remaskAll()
    }

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

    // MARK: - Add, edit, fill and delete

    func add() {
        guard canEdit else { return }
        dependencies.actions.present(.itemEditor(ItemEditorContext(destinationID: destinationID, mode: .add(kind))))
    }

    func edit(_ row: ConfigRowModel) {
        guard canEdit, !row.isDeleted else { return }
        let mode: ItemEditorContext.Mode = row.hasValue ? .edit(row.id) : .fill(row.id)
        dependencies.actions.present(.itemEditor(ItemEditorContext(destinationID: destinationID, mode: mode)))
    }

    func fill(_ row: ConfigRowModel) {
        guard canEdit, !row.hasValue, !row.isDeleted else { return }
        dependencies.actions.present(.itemEditor(ItemEditorContext(destinationID: destinationID, mode: .fill(row.id))))
    }

    func requestDeletion(of rows: [ConfigRowModel]) {
        let live = rows.filter { !$0.isDeleted }
        guard canEdit, !live.isEmpty else { return }
        pendingDeletion = live
    }

    func deleteSelection() {
        requestDeletion(of: selectedRows)
    }

    /// Pushed items become pending deletions for the next Sync; the others go at once.
    func confirmDeletion() {
        guard let rows = pendingDeletion else { return }
        pendingDeletion = nil
        let ids = rows.map(\.id)
        ids.forEach(values.hide)
        do {
            try dependencies.destinations.deleteItems(ids)
            selection.subtract(ids)
        } catch {
            alert = error.presentation
        }
    }

    func revert(_ rows: [ConfigRowModel]) {
        let ids = rows.filter { $0.isDeleted || !$0.isSynced || $0.status == .willPush }.map(\.id)
        guard !ids.isEmpty else { return }
        do {
            try dependencies.destinations.revertItems(ids)
        } catch {
            alert = error.presentation
        }
    }

    func canRevert(_ row: ConfigRowModel) -> Bool {
        row.isDeleted || !row.isSynced || row.status == .willPush
    }

    /// Push on Next Sync. On held rows (v0.9.0) it releases their holds and nothing else, so the
    /// next Sync sends them.
    func pushOnNextSync(_ rows: [ConfigRowModel]) {
        let pushable = rows.filter(\.canPushOnNextSync)
        let held = pushable.filter(\.isHeld)
        let ids = pushable.filter { !$0.isHeld }.map(\.id)
        do {
            if !held.isEmpty {
                let released = try dependencies.shareHolds.releaseHold(itemIDs: held.map(\.id))
                notice = HeldShareCopy.released(name: held.count == 1 ? held.first?.name : nil, count: released)
            }
            if !ids.isEmpty {
                try dependencies.destinations.requestPush(ids)
            }
        } catch {
            alert = error.presentation
        }
    }

    /// The Held chip's tooltip, naming the share file's sender when it is known.
    func heldHelp(for row: ConfigRowModel) -> String {
        HeldShareCopy.chipHelp(sender: row.heldBy.flatMap { heldSenders.name(of: $0) })
    }

    // MARK: - Import and paste

    func pasteMultiple() {
        presentImport(.pasteEditor)
    }

    func importEnvFile() {
        presentImport(.chooser)
    }

    func validatePaste(_ providers: [NSItemProvider]) -> [NSItemProvider]? {
        canEdit ? providers : nil
    }

    func handlePaste(_ providers: [NSItemProvider]) async {
        guard canEdit else { return }
        if dependencies.clipboard.holdsItemNames {
            pasteCopiedItems()
            return
        }
        guard let text = await ItemPasteText.plainText(from: providers), !text.allSatisfy(\.isWhitespace) else { return }
        presentImport(.pasted(EnvPasteBuffer(SecretBytes(utf8: text))))
    }

    private func presentImport(_ start: EnvImportContext.Start) {
        guard canEdit else { return }
        dependencies.actions.present(.envImport(EnvImportContext(place: place, defaultKind: kind, start: start)))
    }

    func exportEnv() {
        dependencies.actions.present(.envExport(EnvExportContext(destinationID: destinationID)))
    }

    // MARK: - Copy and paste between places

    /// Copy To: the repository's scopes (none for a Key Vault of its own).
    var scopeCopyTargets: [ItemCopyTargetModel] {
        guard let repositoryID else { return [] }
        return ((try? dependencies.config.scopes(repositoryID: repositoryID)) ?? [])
            .filter { !$0.isDeleted }
            .map { ItemCopyTargetModel(place: .scope(repositoryID: repositoryID, scope: $0.scope), title: $0.title, isEditable: true) }
    }

    var folderCopyTargets: [ItemCopyTargetModel] {
        dependencies.folderCopyTargets()
    }

    /// Copy To › Destinations: the repository's other destinations, or the other Key Vaults of
    /// their own.
    var destinationCopyTargets: [ItemCopyTargetModel] {
        dependencies.destinationCopyTargets(repositoryID: repositoryID, excluding: destinationID)
    }

    func copySelection() {
        let rows = selectedRows.filter { !$0.isDeleted }
        guard let first = rows.first else { return }
        dependencies.clipboard.copyItems(CopiedItemsModel(ids: rows.map(\.id), names: rows.map(\.name), source: place))
        notice = rows.count == 1
            ? String(
                localized: "destination.copiedItem.notice",
                defaultValue: "Copied \(first.name). Open a scope, folder or destination and paste it with ⌘V: the copy stays linked to this item."
            )
            : String(
                localized: "destination.copiedItems.notice",
                defaultValue: "Copied \(rows.count) items. Open a scope, folder or destination and paste them with ⌘V: the copies stay linked to these items."
            )
    }

    func copy(_ rows: [ConfigRowModel], to target: ItemCopyTargetModel) {
        request(rows.filter { !$0.isDeleted }.map(\.id), to: target)
    }

    func copyToOtherRepository(_ rows: [ConfigRowModel]) {
        let live = rows.filter { !$0.isDeleted }
        guard !live.isEmpty else { return }
        dependencies.actions.present(.copyToRepository(CopyToRepositoryContext(itemIDs: live.map(\.id), source: place)))
    }

    var pendingCopy: ItemCopyRequestModel? {
        get { copyFlow.pendingCopy }
        set { copyFlow.pendingCopy = newValue }
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

    private func pasteCopiedItems() {
        guard let copied = dependencies.clipboard.itemsToPaste else {
            notice = String(
                localized: "main.detail.paste.expired",
                defaultValue: "The copied items are no longer available (FX Vault was locked). Select them and press ⌘C again."
            )
            return
        }
        guard copied.source != place else {
            notice = String(
                localized: "destination.paste.same",
                defaultValue: "These items are already in this destination. Open another scope, folder or destination to paste them."
            )
            return
        }
        request(copied.ids, to: ItemCopyTargetModel(place: place, title: destination?.copyTargetTitle ?? "", isEditable: canEdit))
    }

    private func request(_ ids: [ConfigItemID], to target: ItemCopyTargetModel) {
        guard !ids.isEmpty else { return }
        do {
            if let result = try copyFlow.request(ids, to: target) {
                notice = result.notice(target: target.title)
            }
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - Linked copies

    func showLinkedCopies(of row: ConfigRowModel) {
        do {
            linkedCopies = try dependencies.config.linkedCopies(of: row.id)
            linkedPopoverRowID = row.id
        } catch {
            alert = error.presentation
        }
    }

    func openLinkedCopy(_ copy: LinkedCopyModel) {
        linkedPopoverRowID = nil
        dependencies.actions.openPlace(copy.itemPlace)
    }

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

    // MARK: - Refresh (R6)

    /// Lists the destination and shows how it differs from the vault.
    func refreshNow() {
        guard !isRefreshing, let destination else { return }
        guard dependencies.connectivity.isOnline else {
            alert = ErrorPresentationModel(title: DestinationCopy.refreshFailedTitle, message: ConnectivityCopy.offlineHelp)
            return
        }
        isRefreshing = true
        let sync = dependencies.destinationSync
        tasks.set("refresh", Task { [weak self] in
            do throws(DestinationSyncError) {
                let result = try await sync.refresh(destinationID: destination.id)
                self?.refresh = DestinationRefreshPresentationModel(result)
            } catch {
                self?.alert = error.presentation(provider: destination.provider)
            }
            self?.isRefreshing = false
        })
    }

    /// Review: the drift sheet for this destination.
    func reviewDifferences() {
        guard let refresh, !refresh.findings.isEmpty else { return }
        dependencies.actions.present(.destinationDrift(DestinationDriftContext(destinationID: destinationID, findings: refresh.findings)))
    }

    /// The findings were resolved elsewhere (the drift sheet): drop the banner until the next
    /// Refresh.
    func clearRefresh() {
        refresh = nil
    }

    // MARK: - LockObserving

    func vaultDidLock() {
        values.remaskAll()
        values.clearVariables()
        pendingDeletion = nil
        pendingCopy = nil
        linkedPopoverRowID = nil
        refresh = nil
    }
}

extension DestinationDetailViewModel: ConfigTableModel {}

/// Refresh's result as the banner shows it.
struct DestinationRefreshPresentationModel: Equatable {
    let findings: [DestinationDriftModel]
    let unusable: [DestinationUnusableItemModel]
    let listedAt: Date

    init(_ result: DestinationRefreshModel) {
        findings = result.findings
        unusable = result.unusable
        listedAt = result.listedAt
    }
}

extension ConfigRowModel {
    /// A destination item's row (v0.8.0): pending changes as in a repository scope.
    init(_ item: DestinationItemModel) {
        id = item.id
        name = item.name
        kind = item.kind
        hasValue = item.hasValue
        isDeleted = item.isDeleted
        isSynced = item.isSynced
        updatedAt = item.updatedAt
        status = item.syncStatus
        syncedName = nil
        linkCount = item.isLinked ? item.linkCount : 0
        heldBy = item.heldBy
    }
}
