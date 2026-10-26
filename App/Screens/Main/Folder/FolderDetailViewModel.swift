import Foundation
import Observation
import VaultCore
import VaultData

/// Column 3 for a folder (v0.7.0, tasks/todo.md F4–F6): the folder's name and counts, the
/// Secrets | Variables pill with Add, Paste Multiple… and Import .env, and the table without the
/// Status column (a folder never syncs: every change is saved at once).
///
/// Values follow the repository rules (``ConfigValueRevealer``): a secret is decrypted only while
/// revealed and masked again after 30 s, on resign active, on another selection and on lock.
/// ⌘C copies the selected items for ⌘V in a scope, repository or another folder; Copy To lists
/// the other folders and Another Repository…; every copy stays linked to its source.
@Observable
final class FolderDetailViewModel: LockObserving {
    let folderID: FolderID
    var kind: ConfigKind = .secret {
        didSet {
            if kind != oldValue {
                selection.removeAll()
            }
        }
    }
    private(set) var items: [FolderItemModel] = []
    /// Revealed secrets and decrypted variables.
    let values: ConfigValueRevealer
    /// Reveal in the notes, after Touch ID or the master password (1.0 B9).
    let notesReveal: NotesRevealModel
    /// Copy and paste with "Replace or keep?".
    let copyFlow: ItemCopyFlow
    var selection: Set<ConfigItemID> = []
    var alert: ErrorPresentationModel?
    /// A short confirmation ("Copied API_KEY…").
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

    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let folderProvider: () -> FolderModel?
    @ObservationIgnored private let tasks = TaskBag()

    /// - Parameter folder: the live folder row (its name and counts follow the sidebar).
    init(folderID: FolderID, dependencies: FeatureDependencies, folder: @escaping () -> FolderModel?) {
        self.folderID = folderID
        self.dependencies = dependencies
        folderProvider = folder
        values = ConfigValueRevealer(config: dependencies.config, clock: dependencies.clock)
        notesReveal = NotesRevealModel(values: values, dependencies: dependencies)
        copyFlow = ItemCopyFlow(dependencies: dependencies)
        dependencies.actions.addLockObserver(self)
        observeItems()
    }

    var folder: FolderModel? {
        folderProvider()
    }

    private var place: ItemPlaceModel {
        .folder(folderID)
    }

    // MARK: - Table

    func rows(of kind: ConfigKind) -> [ConfigRowModel] {
        items
            .filter { $0.kind == kind }
            .sorted { $0.name < $1.name }
            .map(ConfigRowModel.init)
    }

    func count(of kind: ConfigKind) -> Int {
        items.lazy.filter { $0.kind == kind }.count
    }

    /// "Folder · never sent anywhere by itself · 4 secrets · 1 variable" (board Folder-View).
    var subline: String {
        PlaceCopy.subline([
            PlaceCopy.folder,
            PlaceCopy.folderNote,
            PlaceCopy.counts(secrets: count(of: .secret), variables: count(of: .variable)),
        ])
    }

    /// A folder's items can always change while the vault is unlocked.
    var canEdit: Bool {
        folder != nil
    }

    var showsSyncStatus: Bool {
        false
    }

    func display(for row: ConfigRowModel) -> ConfigValueDisplayModel {
        values.display(for: row)
    }

    func rows(for ids: Set<ConfigItemID>) -> [ConfigRowModel] {
        rows.filter { ids.contains($0.id) }
    }

    func clearSelection() {
        selection.removeAll()
    }

    private func observeItems() {
        let stream = dependencies.folders.observeItems(folderID: folderID)
        tasks.set("items", Task { [weak self] in
            do {
                for try await items in stream {
                    self?.apply(items)
                }
            } catch {
                AppLog.ui.error("Folder item observation ended")
            }
        })
    }

    /// Applies a new snapshot of the folder's items.
    func apply(_ items: [FolderItemModel]) {
        self.items = items
        values.follow(liveIDs: Set(items.map(\.id)), variableIDs: items.filter { $0.kind == .variable }.map(\.id))
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

    /// Masks every revealed value (resign active, another selection, lock).
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

    func copyAll() {
        dependencies.actions.present(.copyAll(CopyAllContext(place: .place(place))))
    }

    // MARK: - Add, edit and delete

    func add() {
        guard canEdit else { return }
        dependencies.actions.present(.itemEditor(ItemEditorContext(folderID: folderID, mode: .add(kind))))
    }

    func addFileSecret(from url: URL?) {
        guard canEdit else { return }
        kind = .secret
        dependencies.actions.present(.fileSecret(FileSecretContext(place: .folder(folderID), fileURL: url)))
    }

    func edit(_ row: ConfigRowModel) {
        guard canEdit else { return }
        dependencies.actions.present(.itemEditor(ItemEditorContext(folderID: folderID, mode: .edit(row.id))))
    }

    func requestDeletion(of rows: [ConfigRowModel]) {
        guard canEdit, !rows.isEmpty else { return }
        pendingDeletion = rows
    }

    /// ⌫ on the table: Delete… for the selected rows.
    func deleteSelection() {
        requestDeletion(of: selectedRows)
    }

    /// The "Delete?" sheet of ``pendingDeletion``.
    var deletionSheet: DeleteItemsSheetModel? {
        pendingDeletion.map {
            DeleteItemsSheetModel(entries: $0.map(DeleteItemsSheetModel.Entry.init), place: folder?.name ?? "", target: .folder)
        }
    }

    /// Deletes at once (a folder has no GitHub side); linked copies elsewhere stay.
    func confirmDeletion() {
        guard let rows = pendingDeletion else { return }
        pendingDeletion = nil
        let ids = rows.map(\.id)
        ids.forEach(values.hide)
        do {
            try dependencies.folders.deleteItems(ids)
            selection.subtract(ids)
        } catch {
            alert = error.presentation
        }
    }

    // MARK: - Import and paste

    func pasteMultiple() {
        presentImport(.pasteEditor)
    }

    func importEnvFile() {
        presentImport(.chooser)
    }

    /// The ⌘V validator: the providers while the folder can change.
    func validatePaste(_ providers: [NSItemProvider]) -> [NSItemProvider]? {
        canEdit ? providers : nil
    }

    /// ⌘V in the folder: items FX Vault copied, or `.env` text for the import preview.
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

    // MARK: - Copy and paste between places

    /// Copy To: a folder has no scopes of its own.
    var scopeCopyTargets: [ItemCopyTargetModel] {
        []
    }

    /// Copy To › Folder: the other folders.
    var folderCopyTargets: [ItemCopyTargetModel] {
        dependencies.folderCopyTargets(excluding: folderID)
    }

    func copySelection() {
        let rows = selectedRows
        guard let first = rows.first else { return }
        dependencies.clipboard.copyItems(CopiedItemsModel(ids: rows.map(\.id), names: rows.map(\.name), source: place))
        notice = rows.count == 1
            ? String(
                localized: "folder.copiedItem.notice",
                defaultValue: "Copied \(first.name). Open a scope, repository or another folder and paste it with ⌘V: the copy stays linked to this item."
            )
            : String(
                localized: "folder.copiedItems.notice",
                defaultValue: "Copied \(rows.count) items. Open a scope, repository or another folder and paste them with ⌘V: the copies stay linked to these items."
            )
    }

    func copy(_ rows: [ConfigRowModel], to target: ItemCopyTargetModel) {
        request(rows.map(\.id), to: target)
    }

    func copyToOtherRepository(_ rows: [ConfigRowModel]) {
        guard !rows.isEmpty else { return }
        dependencies.actions.present(.copyToRepository(CopyToRepositoryContext(itemIDs: rows.map(\.id), source: place)))
    }

    /// A copy waiting for "Replace or keep?".
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

    /// ⌘V while the pasteboard still holds names FX Vault copied: their items into this folder.
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
                localized: "folder.paste.sameFolder",
                defaultValue: "These items are already in this folder. Open another folder, scope or repository to paste them."
            )
            return
        }
        request(copied.ids, to: ItemCopyTargetModel(place: place, title: folder?.name ?? "", isEditable: canEdit))
    }

    private func request(_ ids: [ConfigItemID], to target: ItemCopyTargetModel) {
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

    // MARK: - Folder actions

    /// Export .env… of the whole folder.
    func exportEnv() {
        dependencies.actions.present(.envExport(EnvExportContext(folderID: folderID)))
    }

    /// Share › File… of the whole folder (a `.fxvault` copy).
    func shareAsFile() {
        dependencies.actions.present(.shareExport(ShareExportContext(selection: .folder(folderID))))
    }

    // MARK: - LockObserving

    func vaultDidLock() {
        values.remaskAll()
        values.clearVariables()
        pendingDeletion = nil
        pendingCopy = nil
        linkedPopoverRowID = nil
    }
}

extension FolderDetailViewModel: ConfigTableModel {}

extension FolderDetailViewModel: NotesPlaceModel {
    var notesPlaceName: String {
        folder?.name ?? ""
    }
}

extension ConfigRowModel {
    /// A folder item's row: always with a value, never synced (v0.7.0).
    init(_ item: FolderItemModel) {
        id = item.id
        name = item.name
        kind = item.kind
        hasValue = true
        isDeleted = false
        isSynced = false
        updatedAt = item.updatedAt
        // Not shown: a folder's table has no Status column.
        status = .added
        syncedName = nil
        linkCount = item.isLinked ? item.linkCount : 0
        file = item.file
    }
}

/// The plain text of a ⌘V, shared by the detail columns.
enum ItemPasteText {
    /// The first provider's plain text, or nil.
    static func plainText(from providers: [NSItemProvider]) async -> String? {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { @Sendable text, _ in
                continuation.resume(returning: text)
            }
        }
    }
}
