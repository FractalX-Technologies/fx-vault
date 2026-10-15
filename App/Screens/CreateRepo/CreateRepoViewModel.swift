import Foundation
import GitHubKit
import Observation
import VaultCore
import VaultData

/// New Repository (⌘N, §10 `CreateRepoScreen`, M4, D18).
///
/// Collects the owner (the gh account or one of its organizations, A5), the name with a
/// debounced "probably available" check (§8 B2), description, visibility, README, `.gitignore`
/// and license templates (B10, cached by `RepoCreationRepository`), staged environments with
/// their deployment branch policy, staged secrets and variables, and "Clone to my Mac".
///
/// **Create stages everything locally** (`RepoCreationRepository.stage`, one transaction):
/// nothing reaches GitHub until the toolbar Sync, which creates the repository (C1, then B2),
/// its environments, patterns and items in one run (§7.3 step 1) and clones it afterwards.
///
/// Values typed here exist only in this view model until Create; they are never logged or part
/// of a summary, and are dropped after staging, on Cancel and on lock (``LockObserving``).
@Observable
final class CreateRepoViewModel: LockObserving {
    enum Phase: Equatable {
        case loading
        case ready
        /// gh is not ready, lists no account, or failed.
        case loadFailed(ErrorPresentationModel)
        case staging
        case staged(CreateRepoStagedModel)
    }

    /// The visibilities offered (internal is an Enterprise feature gh creates differently).
    static let visibilityOptions: [RepoVisibility] = [.private, .public]

    private(set) var phase: Phase = .loading
    /// Logins of the gh accounts that can create repositories.
    private(set) var accounts: [String] = []
    var accountLogin: String? {
        didSet {
            if accountLogin != oldValue {
                accountDidChange()
            }
        }
    }

    private(set) var owners: [RepoOwnerChoiceModel] = []
    var ownerID: RepoOwnerChoiceModel.ID? {
        didSet {
            if ownerID != oldValue {
                scheduleAvailabilityCheck()
            }
        }
    }

    /// The organizations could not be listed (only the personal account is offered).
    private(set) var ownersWarning: ErrorPresentationModel?
    private(set) var isLoadingAccountData = false

    var name = "" {
        didSet {
            if name != oldValue {
                scheduleAvailabilityCheck()
            }
        }
    }

    private(set) var availability: CreateRepoAvailabilityModel = .idle
    var repoDescription = ""
    var visibility: RepoVisibility = .private
    var addsReadme = true
    /// The `.gitignore` template name, or nil for none.
    var gitignoreTemplate: String?
    /// The license key, or nil for none.
    var licenseKey: String?
    private(set) var gitignoreTemplates: [String] = []
    private(set) var licenseTemplates: [GHLicenseTemplateModel] = []
    private(set) var templatesError: ErrorPresentationModel?

    private(set) var repositoryItems: [CreateRepoItemDraftModel] = []
    private(set) var environments: [CreateRepoEnvironmentDraftModel] = []

    /// "Clone to my Mac" (on by default, §10): Sync clones the new repository into the clone
    /// folder through the account's SSH alias.
    var clonesAfterCreate = true

    /// The nested item or environment editor on screen.
    var editor: CreateRepoEditorRoute?
    /// Cancel with typed input asks first.
    var isConfirmingDiscard = false
    var alert: ErrorPresentationModel?

    @ObservationIgnored private let context: CreateRepoContext
    @ObservationIgnored private let creation: RepoCreationRepository
    @ObservationIgnored private let github: GitHubEnvironmentRepository
    @ObservationIgnored private let preferences: PreferencesManager
    @ObservationIgnored private let clock: any VaultClock
    @ObservationIgnored private let actions: MainActions
    @ObservationIgnored private let reachability: GitHubReachability
    @ObservationIgnored private let connectivity: ConnectivityMonitor
    @ObservationIgnored private let tasks = TaskBag()
    /// The owner to preselect on the first owners load (from the context).
    @ObservationIgnored private var preferredOwnerLogin: String?
    /// SSH alias per account fold key (nil: none mapped).
    @ObservationIgnored private var aliases: [String: String] = [:]
    /// The running owners and templates load (tests await it).
    @ObservationIgnored private(set) var accountTask: Task<Void, Never>?
    /// The pending or running availability check (tests await it).
    @ObservationIgnored private(set) var availabilityTask: Task<Void, Never>?

    private enum TaskKey {
        static let account = "account"
        static let availability = "availability"
    }

    init(context: CreateRepoContext, dependencies: FeatureDependencies) {
        self.context = context
        creation = dependencies.creation
        github = dependencies.github
        preferences = dependencies.preferences
        clock = dependencies.clock
        actions = dependencies.actions
        reachability = dependencies.gitHubReachability
        connectivity = dependencies.connectivity
        preferredOwnerLogin = context.ownerLogin
        dependencies.actions.addLockObserver(self)
    }

    // MARK: - Loading

    /// Lists the gh accounts, then the owners and templates of the preselected one.
    func load() async {
        switch phase {
        case .loading, .loadFailed: break
        case .ready, .staging, .staged: return
        }
        phase = .loading
        guard actions.isGitHubReady() else {
            phase = .loadFailed(Self.ghNotReady)
            return
        }
        let summaries: [GHAccountSummaryModel]
        do {
            summaries = try await github.accounts()
        } catch {
            phase = .loadFailed(error.presentation)
            return
        }
        let loggedIn = summaries.filter(\.isLoggedIn)
        guard let first = loggedIn.first else {
            phase = .loadFailed(Self.noAccounts)
            return
        }
        accounts = loggedIn.map(\.account.login)
        aliases = Dictionary(
            loggedIn.compactMap { summary in summary.account.sshHostAlias.map { (summary.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let preferred = context.accountLogin.flatMap { login in
            accounts.first { OwnerLoginValidator.foldKey($0) == OwnerLoginValidator.foldKey(login) }
        }
        phase = .ready
        accountLogin = preferred ?? first.account.login
        await accountTask?.value
    }

    /// Loads the templates again after a failure.
    func retryTemplates() async {
        guard let account = accountLogin else { return }
        await loadTemplates(account)
    }

    private func accountDidChange() {
        owners = []
        ownerID = nil
        ownersWarning = nil
        templatesError = nil
        gitignoreTemplates = []
        licenseTemplates = []
        guard let account = accountLogin else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await loadAccountData(account)
        }
        accountTask = task
        tasks.set(TaskKey.account, task)
    }

    private func loadAccountData(_ account: String) async {
        isLoadingAccountData = true
        defer { isLoadingAccountData = false }
        let loaded: [RepoOwnerChoiceModel]
        var warning: ErrorPresentationModel?
        do {
            loaded = try await creation.owners(accountLogin: account)
            reachability.recordSuccess()
        } catch {
            reachability.record(error)
            loaded = [RepoOwnerChoiceModel(login: account, ownerType: .user)]
            warning = ErrorPresentationModel(
                title: String(localized: "createRepo.owners.failed", defaultValue: "Organizations could not be listed"),
                message: error.presentation.message
            )
        }
        guard !Task.isCancelled, accountLogin == account else { return }
        owners = loaded
        ownersWarning = warning
        let preferred = preferredOwnerLogin.map(OwnerLoginValidator.foldKey)
        preferredOwnerLogin = nil
        ownerID = loaded.first { $0.id == preferred }?.id ?? loaded.first?.id
        await loadTemplates(account)
    }

    private func loadTemplates(_ account: String) async {
        templatesError = nil
        do {
            let gitignores = try await creation.gitignoreTemplates(accountLogin: account)
            let licenses = try await creation.licenseTemplates(accountLogin: account)
            reachability.recordSuccess()
            guard accountLogin == account else { return }
            gitignoreTemplates = gitignores
            licenseTemplates = licenses
            if let template = gitignoreTemplate, !gitignores.contains(template) {
                gitignoreTemplate = nil
            }
            if let key = licenseKey, !licenses.contains(where: { $0.key == key }) {
                licenseKey = nil
            }
        } catch {
            reachability.record(error)
            guard accountLogin == account else { return }
            templatesError = error.presentation
        }
    }

    // MARK: - Owner and name

    var selectedOwner: RepoOwnerChoiceModel? {
        owners.first { $0.id == ownerID }
    }

    /// Why the name cannot be used; nil while it is empty.
    var nameError: String? {
        guard !name.isEmpty, let rule = RepoNameValidator.violation(in: name) else { return nil }
        return rule.localizedMessage
    }

    /// GitHub's form of an invalid name (`My App` → `My-App`).
    var suggestedName: String? {
        guard !name.isEmpty else { return nil }
        return RepoNameValidator.suggestedFix(for: name)
    }

    func applySuggestedName() {
        if let suggestedName {
            name = suggestedName
        }
    }

    /// Runs B2 for `owner/name` once the name has not changed for
    /// ``CreateRepoConstants/availabilityDebounce`` (a newer edit cancels the pending check).
    private func scheduleAvailabilityCheck() {
        availabilityTask?.cancel()
        availabilityTask = nil
        tasks.cancel(TaskKey.availability)
        guard let account = accountLogin, let owner = selectedOwner, !name.isEmpty else {
            availability = .idle
            return
        }
        if let rule = RepoNameValidator.violation(in: name) {
            availability = .invalid(rule)
            return
        }
        availability = .checking
        let name = name
        let creation = creation
        let clock = clock
        let task = Task { [weak self] in
            do {
                try await clock.sleep(for: CreateRepoConstants.availabilityDebounce)
            } catch {
                return
            }
            let result = await creation.checkAvailability(owner: owner.login, name: name, accountLogin: account)
            guard !Task.isCancelled else { return }
            self?.applyAvailability(result)
        }
        availabilityTask = task
        tasks.set(TaskKey.availability, task)
    }

    private func applyAvailability(_ result: RepoNameAvailabilityModel) {
        availability = switch result {
        case .probablyAvailable: .probablyAvailable
        case .taken: .taken
        case .invalid(.invalidName(let rule)): .invalid(rule)
        case .invalid(let error): .unknown(error.presentation)
        case .unknown(let error): .unknown(error.presentation)
        }
    }

    // MARK: - Clone

    var cloneFolderURL: URL? {
        preferences.cloneFolderURL
    }

    /// Changes the clone folder (Preferences › General keeps the same setting).
    func setCloneFolder(_ url: URL) {
        preferences.setCloneFolder(url)
    }

    /// "Clone to my Mac" is on but no folder is chosen yet.
    var needsCloneFolder: Bool {
        clonesAfterCreate && cloneFolderURL == nil
    }

    /// "Clone to my Mac" is on but the account has no SSH alias mapped (D19): Sync would create
    /// the repository and report the clone as failed.
    var cloneNeedsSSHAlias: Bool {
        guard clonesAfterCreate, let account = accountLogin else { return false }
        return aliases[OwnerLoginValidator.foldKey(account)] == nil
    }

    // MARK: - Environments and items

    /// Environment features on private repositories depend on the GitHub plan (§10 plan note).
    var showsPlanNote: Bool {
        visibility == .private && !environments.isEmpty
    }

    func items(in target: CreateRepoItemTargetModel) -> [CreateRepoItemDraftModel] {
        switch target {
        case .repository:
            repositoryItems
        case .environment(let id):
            environments.first { $0.id == id }?.items ?? []
        }
    }

    func scopeTitle(for target: CreateRepoItemTargetModel) -> String {
        switch target {
        case .repository:
            String(localized: "createRepo.scope.repository", defaultValue: "Repository")
        case .environment(let id):
            environments.first { $0.id == id }?.name ?? ""
        }
    }

    var secretCount: Int {
        count(of: .secret)
    }

    var variableCount: Int {
        count(of: .variable)
    }

    private func count(of kind: ConfigKind) -> Int {
        (repositoryItems + environments.flatMap(\.items)).count { $0.kind == kind }
    }

    func addItem(kind: ConfigKind, to target: CreateRepoItemTargetModel) {
        openItemEditor(item: nil, kind: kind, target: target)
    }

    func editItem(_ id: CreateRepoItemDraftModel.ID, in target: CreateRepoItemTargetModel) {
        guard let item = items(in: target).first(where: { $0.id == id }) else { return }
        openItemEditor(item: item, kind: item.kind, target: target)
    }

    func removeItem(_ id: CreateRepoItemDraftModel.ID, from target: CreateRepoItemTargetModel) {
        var list = items(in: target)
        list.removeAll { $0.id == id }
        setItems(list, in: target)
    }

    private func openItemEditor(item: CreateRepoItemDraftModel?, kind: ConfigKind, target: CreateRepoItemTargetModel) {
        let editor = CreateRepoItemEditorViewModel(
            target: target,
            scopeTitle: scopeTitle(for: target),
            editing: item,
            kind: kind,
            siblings: items(in: target)
        ) { [weak self] saved in
            self?.upsertItem(saved, in: target)
            self?.editor = nil
        }
        self.editor = .item(editor)
    }

    private func upsertItem(_ item: CreateRepoItemDraftModel, in target: CreateRepoItemTargetModel) {
        var list = items(in: target)
        if let index = list.firstIndex(where: { $0.id == item.id }) {
            list[index] = item
        } else {
            list.append(item)
        }
        setItems(list, in: target)
    }

    private func setItems(_ items: [CreateRepoItemDraftModel], in target: CreateRepoItemTargetModel) {
        switch target {
        case .repository:
            repositoryItems = items
        case .environment(let id):
            guard let index = environments.firstIndex(where: { $0.id == id }) else { return }
            environments[index].items = items
        }
    }

    func addEnvironment() {
        openEnvironmentEditor(nil)
    }

    func editEnvironment(_ id: CreateRepoEnvironmentDraftModel.ID) {
        guard let environment = environments.first(where: { $0.id == id }) else { return }
        openEnvironmentEditor(environment)
    }

    /// Removes a staged environment with its items (nothing exists on GitHub yet).
    func removeEnvironment(_ id: CreateRepoEnvironmentDraftModel.ID) {
        environments.removeAll { $0.id == id }
    }

    private func openEnvironmentEditor(_ environment: CreateRepoEnvironmentDraftModel?) {
        let editor = CreateRepoEnvironmentEditorViewModel(
            editing: environment,
            otherEnvironments: environments
        ) { [weak self] saved in
            self?.upsertEnvironment(saved)
            self?.editor = nil
        }
        self.editor = .environment(editor)
    }

    /// Applies an editor result; the environment keeps the items it already has.
    private func upsertEnvironment(_ environment: CreateRepoEnvironmentDraftModel) {
        if let index = environments.firstIndex(where: { $0.id == environment.id }) {
            environments[index].name = environment.name
            environments[index].policy = environment.policy
        } else {
            environments.append(environment)
        }
    }

    /// Closes the nested editor and drops what it holds.
    func dismissEditor() {
        if case .item(let editor) = editor {
            editor.discard()
        }
        editor = nil
    }

    // MARK: - Summary (names and counts only)

    /// The two review lines above Create: what Sync will create. Never contains a value.
    var reviewSummary: [String] {
        var traits = [visibility.localizedTitle]
        if addsReadme {
            traits.append(String(localized: "createRepo.summary.readme", defaultValue: "README"))
        }
        if let gitignoreTemplate {
            traits.append(String(localized: "createRepo.summary.gitignore", defaultValue: "\(gitignoreTemplate) .gitignore"))
        }
        if let licenseKey {
            traits.append(licenseTemplates.first { $0.key == licenseKey }?.name ?? licenseKey)
        }
        let owner = selectedOwner?.login ?? ""
        let title = name.isEmpty ? owner : "\(owner)/\(name)"
        return [
            ([title] + traits).joined(separator: " · "),
            CreateRepoText.contentSummary(
                environments: environments.count,
                secrets: secretCount,
                variables: variableCount
            ),
        ]
    }

    // MARK: - Create

    var canCreate: Bool {
        phase == .ready && accountLogin != nil && selectedOwner != nil && !isLoadingAccountData
            && RepoNameValidator.isValid(name) && !availability.blocksCreate && !needsCloneFolder
    }

    /// Stages the repository with its environments and items in the vault (one transaction).
    /// Nothing is sent to GitHub: the next Sync creates it. Returns true when staged.
    @discardableResult
    func create() async -> Bool {
        guard canCreate, let account = accountLogin, let owner = selectedOwner else { return false }
        let draft = makeDraft(accountLogin: account, owner: owner)
        defer { Self.wipe(draft) }
        let environmentCount = environments.count
        let secrets = secretCount
        let variables = variableCount
        let cloneFolder = clonesAfterCreate
            ? cloneFolderURL?.appending(path: name, directoryHint: .isDirectory)
            : nil
        phase = .staging
        do {
            let result = try await creation.stage(draft)
            dropValues()
            phase = .staged(CreateRepoStagedModel(
                repositoryID: result.repositoryID,
                fullName: "\(owner.login)/\(draft.name)",
                environmentCount: environmentCount,
                secretCount: secrets,
                variableCount: variables,
                cloneFolder: cloneFolder,
                strippedTrailingNewlines: result.strippedTrailingNewlines
            ))
            actions.select(result.repositoryID)
            AppLog.ui.info("Staged a new repository")
            return true
        } catch {
            phase = .ready
            alert = error.presentation
            return false
        }
    }

    private func makeDraft(accountLogin: String, owner: RepoOwnerChoiceModel) -> RepoCreationDraftModel {
        let description = repoDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return RepoCreationDraftModel(
            accountLogin: accountLogin,
            ownerLogin: owner.login,
            ownerType: owner.ownerType,
            name: name,
            description: description.isEmpty ? nil : description,
            visibility: visibility,
            spec: RepoCreateSpecModel(
                autoInit: addsReadme,
                gitignoreTemplate: gitignoreTemplate,
                licenseTemplate: licenseKey,
                cloneAfter: clonesAfterCreate
            ),
            items: repositoryItems.map(Self.draftItem),
            environments: environments.map { environment in
                RepoCreationEnvironmentDraftModel(
                    name: environment.name,
                    policy: environment.policy,
                    items: environment.items.map(Self.draftItem)
                )
            }
        )
    }

    private static func draftItem(_ item: CreateRepoItemDraftModel) -> RepoCreationItemDraftModel {
        RepoCreationItemDraftModel(kind: item.kind, name: item.name, value: SecretBytes(utf8: item.value))
    }

    private static func wipe(_ draft: RepoCreationDraftModel) {
        draft.items.forEach { $0.value.wipe() }
        draft.environments.forEach { $0.items.forEach { $0.value.wipe() } }
    }

    /// Sync Now…: opens the Sync sheet for the staged repository (it reviews before running).
    /// Sync needs the internet: offline the button is disabled and says why (the router would
    /// refuse the sheet anyway).
    var canSyncNow: Bool {
        guard case .staged = phase else { return false }
        return actions.isGitHubReady() && connectivity.isOnline
    }

    /// Shown under Sync Now… while offline.
    var syncNowUnavailableReason: String? {
        connectivity.isOnline ? nil : ConnectivityCopy.offlineHelp
    }

    func syncNow() {
        guard canSyncNow, case .staged(let staged) = phase else { return }
        actions.present(.sync(SyncContext(repositoryIDs: [staged.repositoryID])))
    }

    // MARK: - Cancel and lock

    /// True when Cancel would throw away typed input.
    var hasUnsavedInput: Bool {
        switch phase {
        case .staged, .staging:
            return false
        case .loading, .ready, .loadFailed:
            return !name.isEmpty || !repoDescription.isEmpty || !repositoryItems.isEmpty || !environments.isEmpty
        }
    }

    /// Cancel: returns true when the sheet may close now; otherwise asks first
    /// (``isConfirmingDiscard``).
    func requestCancel() -> Bool {
        guard hasUnsavedInput else {
            dropValues()
            return true
        }
        isConfirmingDiscard = true
        return false
    }

    /// "Discard" in the confirmation: drops everything typed.
    func discard() {
        isConfirmingDiscard = false
        dropValues()
        name = ""
        repoDescription = ""
    }

    /// Drops every staged value and the nested editor's.
    private func dropValues() {
        dismissEditor()
        repositoryItems = []
        environments = []
    }

    func vaultDidLock() {
        availabilityTask?.cancel()
        tasks.cancelAll()
        dropValues()
        isConfirmingDiscard = false
    }

    // MARK: - Messages

    private static var ghNotReady: ErrorPresentationModel {
        ErrorPresentationModel(
            title: String(localized: "createRepo.ghNotReady.title", defaultValue: "GitHub CLI not ready"),
            message: String(
                localized: "createRepo.ghNotReady.message",
                defaultValue: "Creating a repository needs the GitHub CLI with a logged-in account. Check Settings › Accounts."
            )
        )
    }

    private static var noAccounts: ErrorPresentationModel {
        ErrorPresentationModel(
            title: String(localized: "createRepo.noAccounts.title", defaultValue: "No GitHub account"),
            message: String(
                localized: "createRepo.noAccounts.message",
                defaultValue: "Log in with gh auth login, then open New Repository again."
            )
        )
    }
}
