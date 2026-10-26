import EnvTools
import Foundation
import Observation
import SharingKit
import VaultCore
import VaultData

/// Share Securely (v0.9.0, tasks/todo.md P1–P6; board Share-Pick since 1.0): one `.fxvault`
/// format 2 file with several repositories, their GitHub scopes and runtime destinations, and
/// optional folders, opened with a fresh passphrase.
///
/// 1. **What to share**: the repositories (the current one preselected), the repository level
///    and the stages across them (production unchecked; ticking it asks for Touch ID, 1.0 B3b),
///    a tree per repository to adjust, the expiry; live counts (``SharingRepository/previewBundle(_:)``).
/// 2. **Authenticate** with Touch ID or the master password (`.fileExport`, single use; with
///    production, `.productionFileExport`, which the production tick may already hold).
/// 3. **Deliver** (board Share-Passphrase): the sealed file sits 0600 in a private staging folder named
///    ``SharingRepository/defaultFileName(timeZone:)``; Send with AirDrop, Share… (Mail,
///    Messages, any app that takes files) or Save…. A passphrase is shown once. The staged file
///    is removed when the sheet closes.
///
/// Values never reach this view model; the passphrase is held only while the sheet is open.
@Observable
final class ProjectShareViewModel: LockObserving {
    enum Step: Equatable {
        case contents
        case authenticate
        case creating
        case done
    }

    private(set) var step: Step = .contents
    let reauth: ShareReauthModel
    /// The production confirmation: asked when production is ticked, or at Create when the tree
    /// picked a production environment.
    let productionReauth: ShareReauthModel
    let fileName: String

    // MARK: Contents

    private(set) var allRepositories: [RepoModel] = []
    private(set) var chosenRepositoryIDs: [RepoID] = []
    private(set) var stageOptions: [ShareStageOptionModel] = []
    /// Fold keys of the checked stages.
    private(set) var chosenStageKeys: Set<String> = []
    private(set) var includesRepositoryLevel = true
    private(set) var tree: ProjectShareTreeModel?
    private(set) var preview: ShareBundleExportPreviewModel?
    private(set) var isLoading = false
    /// The folder the sheet opened for, named by the title while no repository is chosen.
    private(set) var openedFolderName: String?
    var expiry: ShareExpiryChoice = .default {
        didSet { schedulePreview() }
    }

    // MARK: Done

    /// The passphrase, shown once (`w1-…-w6`); nil until the file is sealed.
    private(set) var passphrase: String?
    /// "I've saved it": unlocks Save and Share.
    var hasSavedPassphrase = false
    private(set) var expiresAt: Date?
    private(set) var savedFileURL: URL?
    private(set) var hasSent = false
    private(set) var isDelivering = false
    private(set) var notice: String?
    var alert: ErrorPresentationModel?

    @ObservationIgnored let delivery: any ShareFileDelivering
    @ObservationIgnored private let context: ShareExportContext
    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let identity: ShareLocalIdentityModel
    @ObservationIgnored private let loader: ProjectShareTreeLoader
    @ObservationIgnored private let stagingRoot: URL?
    @ObservationIgnored private var staging: ShareStagingFolder?
    /// The sealed file waiting to be saved or sent.
    @ObservationIgnored private(set) var stagedFileURL: URL?
    @ObservationIgnored private var isShareInFlight = false
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isClosed = false
    /// Bumped on every tree reload, so a slow load never replaces a newer one.
    @ObservationIgnored private var loadGeneration = 0
    /// Bumped on every preview request, so only the latest one is shown.
    @ObservationIgnored private var previewGeneration = 0
    /// The latest stage and summary updates (``settle()`` waits for them).
    @ObservationIgnored private var stageTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(
        context: ShareExportContext,
        dependencies: FeatureDependencies,
        delivery: any ShareFileDelivering = SystemShareFileDelivery(),
        identity: ShareLocalIdentityModel = .current,
        stagingRoot: URL? = nil
    ) {
        self.context = context
        self.dependencies = dependencies
        self.delivery = delivery
        self.identity = identity
        self.stagingRoot = stagingRoot
        loader = ProjectShareTreeLoader(
            config: dependencies.config,
            destinations: dependencies.destinations,
            folders: dependencies.folders
        )
        let touchIDStatus = dependencies.touchIDStatus()
        reauth = ShareReauthModel(
            purpose: .fileExport,
            reauth: dependencies.reauth,
            session: dependencies.session,
            touchIDStatus: touchIDStatus
        )
        productionReauth = ShareReauthModel(
            purpose: .productionFileExport,
            reauth: dependencies.reauth,
            session: dependencies.session,
            touchIDStatus: touchIDStatus
        )
        fileName = dependencies.sharing.defaultFileName()
        dependencies.actions.addLockObserver(self)
    }

    // MARK: - Loading

    /// Loads the repositories and the tree for the context's selection (once: the
    /// sheet's task runs again when the view reappears).
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        isLoading = true
        defer { isLoading = false }
        if case .folder(let id) = context.selection {
            let name = dependencies.folders.folderName(id)
            openedFolderName = name.isEmpty ? nil : name
        }
        do {
            allRepositories = try await loader.repositories()
            let initial = try await initialSelection()
            chosenRepositoryIDs = initial.repositoryIDs
            try await loadStageOptions()
            chosenStageKeys = initial.stageKeys
            try await reloadTree(applying: initial.selection)
        } catch {
            alert = error.presentation
        }
    }

    /// What the sheet starts with: a repository opens with its non-production stages, an
    /// environment, an item or a subset opens with exactly that, a folder with that folder.
    private func initialSelection() async throws -> (repositoryIDs: [RepoID], stageKeys: Set<String>, selection: ShareBundleSelectionModel?) {
        switch context.selection {
        case .folder(let id):
            return ([], [], ShareBundleSelectionModel(folderIDs: [id]))
        case .repository(let id):
            let options = try await dependencies.sharing.stageOptions(repositoryIDs: [id])
            let shareable = Set(options.filter { !$0.isProduction }.map(\.id))
            return ([id], shareable, nil)
        case .environment(let id):
            let repositoryID = try await ShareScopeTreeLoader(config: dependencies.config, sharing: dependencies.sharing)
                .repositoryID(for: context.selection)
            let part = ShareBundleRepositorySelectionModel(repositoryID: repositoryID, includesRepositoryLevel: false, environmentIDs: [id])
            return ([repositoryID], [], ShareBundleSelectionModel(repositories: [part]))
        case .item(let id):
            let repositoryID = try await ShareScopeTreeLoader(config: dependencies.config, sharing: dependencies.sharing)
                .repositoryID(for: context.selection)
            let part = ShareBundleRepositorySelectionModel(repositoryID: repositoryID, includesRepositoryLevel: false, itemIDs: [id])
            return ([repositoryID], [], ShareBundleSelectionModel(repositories: [part]))
        case .subset(let subset):
            let part = ShareBundleRepositorySelectionModel(
                repositoryID: subset.repositoryID,
                includesRepositoryLevel: false,
                environmentIDs: subset.environmentIDs,
                itemIDs: subset.itemIDs
            )
            return ([subset.repositoryID], [], ShareBundleSelectionModel(repositories: [part]))
        }
    }

    // MARK: - Step 1: repositories

    var chosenRepositories: [RepoModel] {
        chosenRepositoryIDs.compactMap { id in allRepositories.first { $0.id == id } }
    }

    /// Repositories that can still be added.
    var addableRepositories: [RepoModel] {
        allRepositories.filter { !chosenRepositoryIDs.contains($0.id) }
    }

    func addRepository(_ id: RepoID) async {
        guard !chosenRepositoryIDs.contains(id), chosenRepositoryIDs.count < Limits.maxShareRepositories else { return }
        chosenRepositoryIDs.append(id)
        await repositoriesChanged()
    }

    func removeRepository(_ id: RepoID) async {
        chosenRepositoryIDs.removeAll { $0 == id }
        await repositoriesChanged()
    }

    private func repositoriesChanged() async {
        do {
            try await loadStageOptions()
            let available = Set(stageOptions.map(\.id))
            chosenStageKeys = chosenStageKeys.intersection(available)
            try await reloadTree(applying: try await stageSelection())
        } catch {
            alert = error.presentation
        }
    }

    private func loadStageOptions() async throws {
        stageOptions = try await dependencies.sharing.stageOptions(repositoryIDs: chosenRepositoryIDs)
    }

    // MARK: - Step 1: stages

    func isStageChosen(_ option: ShareStageOptionModel) -> Bool {
        chosenStageKeys.contains(option.id)
    }

    /// Checks or unchecks a stage for every chosen repository. Checking production asks for Touch
    /// ID first; cancelling leaves it unchecked. Without Touch ID it is checked and Create asks for
    /// the password.
    func setStage(_ option: ShareStageOptionModel, chosen: Bool) {
        guard chosen, option.isProduction, !productionReauth.isAuthorized, productionReauth.canUseTouchID else {
            updateStage(option, chosen: chosen)
            return
        }
        stageTask = Task { [weak self] in
            guard let self else { return }
            let authorized = await productionReauth.authorizeWithTouchID(automatic: true)
            // Touch ID turned out unusable: the password at Create confirms production instead.
            guard authorized || !productionReauth.canUseTouchID else { return }
            chosenStageKeys.insert(option.id)
            await applyStageSelection()
        }
    }

    private func updateStage(_ option: ShareStageOptionModel, chosen: Bool) {
        if chosen {
            chosenStageKeys.insert(option.id)
        } else {
            chosenStageKeys.remove(option.id)
        }
        stageTask = Task { [weak self] in await self?.applyStageSelection() }
    }

    /// The repository-level toggle, for every chosen repository.
    func setIncludesRepositoryLevel(_ included: Bool) {
        includesRepositoryLevel = included
        tree?.setRepositoryLevel(included)
        schedulePreview()
    }

    /// The tree's checkbox for one row.
    func setChecked(_ checked: Bool, for node: ShareScopeNodeModel) {
        tree?.setChecked(checked, for: node)
        schedulePreview()
    }

    /// Waits for the stage and preview updates the last change started (tests).
    func settle() async {
        await stageTask?.value
        await previewTask?.value
    }

    private var chosenStageNames: [String] {
        stageOptions.filter { chosenStageKeys.contains($0.id) }.map(\.name)
    }

    private func stageSelection() async throws -> ShareBundleSelectionModel {
        try await dependencies.sharing.selection(
            repositoryIDs: chosenRepositoryIDs,
            stages: chosenStageNames,
            includesRepositoryLevel: includesRepositoryLevel,
            expiry: expiry
        )
    }

    private func applyStageSelection() async {
        do {
            let selection = try await stageSelection()
            tree?.apply(selection)
            await refreshPreview()
        } catch {
            alert = error.presentation
        }
    }

    private func reloadTree(applying selection: ShareBundleSelectionModel?) async throws {
        loadGeneration += 1
        let generation = loadGeneration
        var fresh = try await loader.tree(repositories: chosenRepositories)
        guard generation == loadGeneration else { return }
        if let previous = tree {
            // Keep the folders the user checked.
            fresh.apply(previous.selection(stages: [], expiry: expiry).foldersOnly)
        }
        if let selection {
            fresh.apply(selection)
        } else {
            fresh.apply(try await stageSelection())
        }
        tree = fresh
        await refreshPreview()
    }

    // MARK: - Step 1: summary

    /// What the title names: the one repository chosen, else the folder the sheet opened for;
    /// nil for several.
    var subjectName: String? {
        let repositories = chosenRepositories
        if repositories.count == 1 { return repositories.first?.name }
        return repositories.isEmpty ? openedFolderName : nil
    }

    /// Secrets and variables in the file (the footer); nil until the counts are known.
    var counts: ShareItemCountModel? {
        preview?.summary.counts
    }

    /// What the checked rows share.
    var selection: ShareBundleSelectionModel? {
        guard let tree else { return nil }
        let selection = tree.selection(stages: chosenStageNames, expiry: expiry)
        return selection.isEmpty ? nil : selection
    }

    private func schedulePreview() {
        previewTask = Task { [weak self] in await self?.refreshPreview() }
    }

    /// Recomputes the summary; Create waits for it, so it always describes the checks.
    private func refreshPreview() async {
        previewGeneration += 1
        let generation = previewGeneration
        guard let selection else {
            preview = nil
            return
        }
        preview = nil
        do {
            let fresh = try await dependencies.sharing.previewBundle(selection)
            guard generation == previewGeneration else { return }
            preview = fresh
        } catch {
            guard generation == previewGeneration else { return }
            alert = error.presentation
        }
    }

    func back() {
        guard step == .authenticate else { return }
        // Only the step's own model: a production confirmation from the tick stays.
        activeReauth.reset()
        step = .contents
    }

    /// The file includes production (a stage or an environment picked in the tree).
    var includesProduction: Bool {
        preview?.includesProduction == true
    }

    var productionPlaces: [String] {
        preview?.productionPlaces ?? []
    }

    /// The authentication the file needs: the production confirmation when it includes
    /// production.
    var activeReauth: ShareReauthModel {
        includesProduction ? productionReauth : reauth
    }

    // The preview says whether production is in, which picks the confirmation Create asks for;
    // the file needs an item or a folder.
    var canCreate: Bool {
        step == .contents && selection != nil
            && preview.map { $0.itemCount > 0 || !$0.summary.folders.isEmpty } == true
    }

    /// Moves to the authentication step and tries Touch ID once (no error when it is off). A
    /// production confirmation from the tick is used as it is, without a second prompt.
    func requestCreate() async {
        guard canCreate else { return }
        step = .authenticate
        if activeReauth.isAuthorized {
            await create()
        } else {
            await authenticateWithTouchID(automatic: true)
        }
    }

    // MARK: - Step 2: authenticate

    func authenticateWithTouchID(automatic: Bool = false) async {
        guard step == .authenticate else { return }
        if await activeReauth.authorizeWithTouchID(automatic: automatic) {
            await create()
        }
    }

    func authenticateWithPassword() async {
        guard step == .authenticate else { return }
        if await activeReauth.authorizeWithPassword() {
            await create()
        }
    }

    /// Seals the selection into the staged file. Consumes the authorization: a failure after
    /// that needs a new authentication.
    private func create() async {
        guard let selection, let authorization = activeReauth.takeAuthorization() else {
            step = .contents
            return
        }
        step = .creating
        do {
            let folder = try staging ?? ShareStagingFolder(root: stagingRoot ?? ShareStagingFolder.defaultRoot)
            staging = folder
            let result = try await dependencies.sharing.exportBundle(
                selection,
                to: folder.fileURL(named: fileName),
                senderName: identity.displayName,
                appVersion: identity.appVersion,
                authorization: authorization,
                existingFile: .replace
            )
            let secret = result.passphrase
            defer { secret.wipe() }
            guard let words = secret.utf8String() else { throw SharingError.unexpected }
            passphrase = words
            expiresAt = result.preview.expiresAt
            preview = result.preview
            stagedFileURL = result.fileURL
            step = .done
        } catch {
            alert = error.presentation
            reauth.reset()
            productionReauth.reset()
            step = .contents
        }
    }

    // MARK: - Step 3: deliver

    var canDeliver: Bool {
        step == .done && !isDelivering && stagedFileURL != nil && hasSavedPassphrase
    }

    /// Copies the passphrase (concealed, cleared after 30 s, §5.9).
    func copyPassphrase() {
        guard let passphrase else { return }
        dependencies.clipboard.copy(passphrase)
        notice = ProjectShareCopy.copied(clipboardClearSeconds)
    }

    /// The line under the passphrase: the last notice (copied, saved, sent), else when a copy
    /// clears (board Share-Passphrase).
    var passphraseNote: String {
        notice ?? ProjectShareCopy.clipboardClears(clipboardClearSeconds)
    }

    private var clipboardClearSeconds: Int {
        dependencies.clipboard.clearDelay.wholeSeconds
    }

    /// Save…: asks where, then writes the encrypted file there (0600).
    func saveToFile() async {
        guard canDeliver, let stagedFileURL else { return }
        isDelivering = true
        defer { isDelivering = false }
        guard let destination = await delivery.chooseSaveDestination(suggestedName: fileName) else { return }
        do {
            let data = try Data(contentsOf: stagedFileURL, options: .uncached)
            try SecureFileWriter().write(data, to: destination, existingFile: .replace)
            savedFileURL = destination
            notice = ProjectShareCopy.saved(destination.lastPathComponent)
        } catch let error as SecureFileWriteError {
            alert = SharingError.write(error).presentation
        } catch {
            alert = SharingError.fileUnreadable.presentation
        }
    }

    /// Share…: the system sharing picker (Mail, Messages, AirDrop and apps that take files).
    func shareFile() {
        guard canDeliver, let stagedFileURL else { return }
        isDelivering = true
        isShareInFlight = true
        delivery.share(fileURL: stagedFileURL) { [weak self] outcome in
            self?.deliveryFinished(outcome)
        }
    }

    /// Send with AirDrop is shown only where this Mac offers AirDrop.
    var canSendWithAirDrop: Bool {
        stagedFileURL.map(delivery.canSendWithAirDrop(fileURL:)) == true
    }

    /// Send with AirDrop: the system AirDrop window for the same passphrase file (1.0, B3b). The
    /// receiver opens it as any `.fxvault` file.
    func sendWithAirDrop() {
        guard canDeliver, canSendWithAirDrop, let stagedFileURL else { return }
        isDelivering = true
        isShareInFlight = true
        delivery.sendWithAirDrop(fileURL: stagedFileURL) { [weak self] outcome in
            self?.deliveryFinished(outcome)
        }
    }

    private func deliveryFinished(_ outcome: ShareDeliveryOutcome) {
        isDelivering = false
        isShareInFlight = false
        switch outcome {
        case .shared:
            hasSent = true
            notice = ProjectShareCopy.sent
        case .cancelled:
            break
        case .failed:
            alert = ErrorPresentationModel(
                title: String(localized: "share.export.sendFailed.title", defaultValue: "Couldn't send the file"),
                message: String(
                    localized: "share.export.sendFailed.message",
                    defaultValue: "Try again, or save the file and send it another way."
                )
            )
        }
        if isClosed {
            removeStaging()
        }
    }

    // MARK: - Lifetime

    /// The sheet closed: drops the passphrase and the authorization and removes the staged file
    /// (after a running hand-off finishes).
    func close() {
        isClosed = true
        wipe()
        if !isShareInFlight {
            removeStaging()
        }
    }

    func vaultDidLock() {
        wipe()
        if step == .authenticate || step == .creating {
            step = .contents
        }
    }

    private func wipe() {
        passphrase = nil
        hasSavedPassphrase = false
        notice = nil
        reauth.reset()
        productionReauth.reset()
    }

    private func removeStaging() {
        staging?.remove()
        staging = nil
        stagedFileURL = nil
    }
}

private extension ShareBundleSelectionModel {
    /// The same selection with its folders only.
    var foldersOnly: ShareBundleSelectionModel {
        ShareBundleSelectionModel(folderIDs: folderIDs, stages: stages, expiry: expiry)
    }
}
