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
    }

    /// True when Revert has something to undo (a synced item with a local change).
    var canRevert: Bool {
        isSynced && status != .synced && status != .unverifiedShare
    }
}

/// Column 3 (§10): the header (owner/name, visibility, capability chip, Clone, Refresh, drift
/// banner, deployment branches and plan note on environments, read-only explanation) and one
/// table with the Secrets | Variables picker and the row actions.
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
    private(set) var revealedValues: [ConfigItemID: String] = [:]
    private(set) var variableValues: [ConfigItemID: String] = [:]
    var selection: Set<ConfigItemID> = []
    private(set) var driftReport: DriftReportModel?
    /// Why the last drift check failed (shown as a small note); nil otherwise.
    private(set) var driftError: ErrorPresentationModel?
    private(set) var isRefreshing = false
    var alert: ErrorPresentationModel?
    /// A short confirmation ("Copied API_TOKEN. The clipboard clears in 30 seconds.").
    private(set) var notice: String?
    /// The item waiting for the "Delete?" confirmation.
    var pendingDeletion: ConfigRowModel?

    /// The scheduled re-mask of each revealed value (internal so tests can await it).
    @ObservationIgnored private(set) var remaskTasks: [ConfigItemID: Task<Void, Never>] = [:]
    @ObservationIgnored private(set) var driftTask: Task<Void, Never>?
    /// A drift check was asked for while offline and skipped: the reconnect check re-lists.
    @ObservationIgnored private var missedDriftCheckOffline = false
    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let repositoryProvider: () -> RepoModel?
    @ObservationIgnored private let scopeProvider: (ConfigScope) -> ConfigScopeSummaryModel?
    @ObservationIgnored private let tasks = TaskBag()

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
        guard row.hasValue else { return .missing }
        switch row.kind {
        case .secret:
            return revealedValues[row.id].map(ConfigValueDisplayModel.revealed) ?? .masked
        case .variable:
            return variableValues[row.id].map(ConfigValueDisplayModel.plain) ?? .masked
        }
    }

    // MARK: - Scope

    /// Shows another scope of the repository: masks everything and observes its items.
    func select(scope: ConfigScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        selection.removeAll()
        remaskAll()
        variableValues.removeAll()
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

    /// Applies a new snapshot of the scope's items.
    func apply(_ items: [ConfigItemModel]) {
        self.items = items
        let ids = Set(items.map(\.id))
        for id in revealedValues.keys where !ids.contains(id) {
            hide(id)
        }
        loadVariableValues()
    }

    /// Decrypts the scope's variables for plaintext display. A locked vault shows them masked.
    private func loadVariableValues() {
        var values: [ConfigItemID: String] = [:]
        for item in items where item.kind == .variable && item.hasValue {
            do {
                let value = try dependencies.config.reveal(item.id)
                values[item.id] = value.utf8String()
                value.wipe()
            } catch {
                continue
            }
        }
        variableValues = values
    }

    // MARK: - Reveal and copy (§5.9, §5.11)

    func isRevealed(_ id: ConfigItemID) -> Bool {
        revealedValues[id] != nil
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
            let value = try dependencies.config.reveal(id)
            defer { value.wipe() }
            guard let text = value.utf8String() else { throw ConfigRepositoryError.unexpected }
            revealedValues[id] = text
        } catch {
            alert = error.presentation
            return
        }
        remaskTasks[id]?.cancel()
        let clock = dependencies.clock
        remaskTasks[id] = Task { [weak self] in
            do {
                try await clock.sleep(for: Timeouts.revealRemask)
            } catch {
                return
            }
            self?.hide(id)
        }
    }

    func hide(_ id: ConfigItemID) {
        remaskTasks.removeValue(forKey: id)?.cancel()
        revealedValues.removeValue(forKey: id)
    }

    /// Masks every revealed value (resign active, scope change, lock).
    func remaskAll() {
        for task in remaskTasks.values {
            task.cancel()
        }
        remaskTasks.removeAll()
        revealedValues.removeAll()
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

    /// "Import .env File…" from the Add menu: the file chooser, rows defaulting to the tab's kind.
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
        guard canEdit, let text = await Self.plainText(from: providers) else { return }
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

    func requestDeletion(_ row: ConfigRowModel) {
        guard canEdit, !row.isDeleted else { return }
        if row.isSynced {
            pendingDeletion = row
        } else {
            delete(row)
        }
    }

    func confirmDeletion() {
        guard let row = pendingDeletion else { return }
        pendingDeletion = nil
        delete(row)
    }

    private func delete(_ row: ConfigRowModel) {
        hide(row.id)
        do {
            try dependencies.config.deleteItem(row.id)
        } catch {
            alert = error.presentation
        }
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
        variableValues.removeAll()
        driftTask?.cancel()
        driftReport = nil
        pendingDeletion = nil
    }
}
