import AppKit
import Foundation
import GitHubKit
import Observation
import SyncEngine
import VaultCore
import VaultData

/// The Sync sheet (§7.2–§7.5, §10 Sheets, M3): Summary → Deletions (live fetch) → Progress →
/// Result.
///
/// - **Summary** shows names and counts only, never values: per repository and scope, blocked
///   changes with their reason and fix, changes routed to Drift review (D27), the FX Vault write
///   limit, and the credential-looking variables the user must confirm (§5.13).
/// - **From Files** (v0.9.0, P8): rows imported from share files wait until the user includes
///   their file, one toggle per file, off by default; the summary, the counts and the run follow
///   the choice (``includedHeldShares``).
/// - **Deletions** (§7.5) lists every deletion with the environments' live contents; the run
///   with deletions needs "I understand this cannot be undone" (and, when a fetch failed, the
///   contents-unknown acknowledgement). Neither button is the default.
/// - **Progress** holds a ``SyncActivity`` (auto-lock inactivity suspended, D16) from before the
///   run starts until its outcome is in.
/// - **Result** has Failed / Blocked / Skipped / Succeeded sections with localized reasons and
///   fixes, the stop reason, warnings and the clones the run requested.
@Observable
final class SyncViewModel: LockObserving {
    private(set) var step: SyncSheetStepModel = .loading
    private(set) var review: SyncReviewModel?
    /// The destination changes of the repositories in this sync (v0.8.0), reviewed after GitHub's.
    private(set) var destinationReviews: [DestinationReviewModel] = []
    /// The organizations with changes (1.0), reviewed when the sync covers every repository.
    private(set) var organizationReviews: [OrgReviewModel] = []
    /// Share files whose imported rows wait for the From Files review (v0.9.0), newest import
    /// first, limited to the repositories of this sync.
    private(set) var heldShares: [HeldShareModel] = []
    /// The share files this run includes; none until the user turns one on.
    private(set) var includedHeldShares: Set<SharePackageID> = []
    private(set) var repositories: [SyncSummaryRepoModel] = []
    private(set) var credentialRows: [SyncCredentialRowModel] = []
    /// "Push these as variables anyway" (§5.13). Required when ``credentialRows`` is not empty.
    var credentialsConfirmed = false

    /// The §7.5 live fetch; nil while loading.
    private(set) var deletionPreviews: [RepoDeletionPreviewModel]?
    /// "I understand this cannot be undone".
    var deletionsAcknowledged = false
    /// The extra acknowledgement when an environment's contents could not be fetched.
    var unknownContentsAcknowledged = false

    private(set) var progress = SyncRunProgressModel()
    private(set) var outcome: SyncRunOutcomeModel?
    private(set) var resultSections: [SyncResultSectionModel] = []
    private(set) var clones: [SyncCloneRowModel] = []

    /// A short confirmation ("Command copied…").
    private(set) var notice: String?
    var alert: ErrorPresentationModel?


    let context: SyncContext
    @ObservationIgnored private let dependencies: FeatureDependencies
    @ObservationIgnored private let service: any SyncServicing
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored private let chooseCloneFolder: () -> URL?
    @ObservationIgnored private var run: (any SyncRunControlling)?
    @ObservationIgnored private var changeNames: [String: String] = [:]
    @ObservationIgnored private var environmentNames: [String: String] = [:]
    @ObservationIgnored private var repositoryModels: [RepoID: RepoModel] = [:]
    @ObservationIgnored private var didRequestRefresh = false

    /// - Parameters:
    ///   - service: the sync service; nil uses the live one over `dependencies`.
    ///   - openURL: opens links (SAML authorization, documentation).
    ///   - chooseCloneFolder: asks for a clone folder when Preferences has none (the entry view
    ///     passes `ClonePanel`; the default chooses nothing, so tests and previews never block
    ///     on a panel).
    init(
        context: SyncContext,
        dependencies: FeatureDependencies,
        service: (any SyncServicing)? = nil,
        openURL: @escaping (URL) -> Void = { url in _ = NSWorkspace.shared.open(url) },
        chooseCloneFolder: @escaping () -> URL? = { nil }
    ) {
        self.context = context
        self.dependencies = dependencies
        self.service = service ?? dependencies.syncService
        self.openURL = openURL
        self.chooseCloneFolder = chooseCloneFolder
        dependencies.actions.addLockObserver(self)
    }

    // MARK: - Summary (§7.2, §7.3)

    /// Runs the preflight and shows the summary.
    func load() async {
        step = .loading
        guard dependencies.actions.isGitHubReady() else {
            step = .failed(ErrorPresentationModel(
                title: String(localized: "error.sync.title", defaultValue: "Sync did not run"),
                message: String(
                    localized: "sync.needsGH",
                    defaultValue: "Sync needs the GitHub CLI with a logged-in account. See the GitHub CLI setup, then sync again."
                )
            ))
            return
        }
        do {
            let review = try await service.preflight(repositoryIDs: context.repositoryIDs.map { Array($0) })
            dependencies.gitHubReachability.recordSuccess()
            destinationReviews = await reviewDestinations(review)
            organizationReviews = await reviewOrganizations()
            apply(review)
            step = .summary
        } catch {
            dependencies.gitHubReachability.record(error)
            step = .failed(error.presentation)
        }
    }

    /// The destination reviews of the sync's repositories (all repositories with destination
    /// changes, then the Key Vaults of their own, when the sync covers every repository).
    private func reviewDestinations(_ review: SyncReviewModel) async -> [DestinationReviewModel] {
        let counts = (try? dependencies.destinations.pendingCounts()) ?? [:]
        let ids: [RepoID?] = context.repositoryIDs.map { $0.sorted() } ?? counts.keys.compactMap(\.self).sorted() + [nil]
        var reviews: [DestinationReviewModel] = []
        for id in ids where (counts[id] ?? 0) > 0 {
            let destinationReview = await dependencies.destinationSync.review(repositoryID: id)
            if HeldSharePresentation.hasContent(destinationReview) {
                reviews.append(destinationReview)
            }
        }
        return reviews
    }

    /// The organization reviews: only the toolbar Sync (every repository) sends organizations.
    private func reviewOrganizations() async -> [OrgReviewModel] {
        guard context.repositoryIDs == nil else { return [] }
        let counts = (try? dependencies.organizationItems.pendingCounts()) ?? [:]
        var reviews: [OrgReviewModel] = []
        for id in counts.keys.sorted(by: { $0.uuidString < $1.uuidString }) where (counts[id] ?? 0) > 0 {
            let review = await dependencies.organizationSync.review(organizationID: id)
            if !review.isEmpty {
                reviews.append(review)
            }
        }
        return reviews.sorted { $0.login.localizedStandardCompare($1.login) == .orderedAscending }
    }

    private func apply(_ review: SyncReviewModel) {
        self.review = review
        let scoped = context.repositoryIDs
        heldShares = review.heldShares.filter { share in
            scoped.map { ids in share.repositories.contains { ids.contains($0.id) } } ?? true
        }
        includedHeldShares.formIntersection(heldShares.map(\.packageID))
        credentialRows = []
        credentialsConfirmed = false
        deletionPreviews = nil
        deletionsAcknowledged = false
        unknownContentsAcknowledged = false
        present()
        AppLog.ui.info(
            "Sync review: \(review.preflight.executableCount, privacy: .public) executable, \(review.deletionCount, privacy: .public) deletions, \(self.heldShares.count, privacy: .public) held files"
        )
    }

    /// Turns one share file of the From Files review on or off for this run (v0.9.0).
    func setIncluded(_ packageID: SharePackageID, _ isIncluded: Bool) {
        guard step == .summary, heldShares.contains(where: { $0.packageID == packageID }) else { return }
        if isIncluded {
            includedHeldShares.insert(packageID)
        } else {
            includedHeldShares.remove(packageID)
        }
        present()
    }

    /// The From Files review rows.
    var heldShareRows: [SyncHeldShareRowModel] {
        HeldSharePresentation.rows(heldShares, included: includedHeldShares)
    }

    /// The review as the run would be with the included share files (v0.9.0).
    private var effectiveReview: SyncReviewModel? {
        review.map { HeldSharePresentation.effective($0, including: includedHeldShares) }
    }

    /// The destination reviews with the included share files' held writes.
    private var effectiveDestinationReviews: [DestinationReviewModel] {
        destinationReviews.map { HeldSharePresentation.effective($0, including: includedHeldShares) }
    }

    /// The summary, the credential rows and the progress names of ``effectiveReview``. A change
    /// in the credential rows asks for the confirmation again.
    private func present() {
        guard let review = effectiveReview else { return }
        repositoryModels = [:]
        for repository in review.preflight.repositories {
            repositoryModels[repository.id] = repository.snapshot.repository
        }
        repositories = DestinationSyncPresentation.merge(
            SyncPresentationBuilder.summary(review),
            with: effectiveDestinationReviews,
            fullName: fullName(of:)
        ) + OrgSyncPresentation.summary(organizationReviews)
        let rows = SyncPresentationBuilder.credentialRows(review)
        if rows != credentialRows {
            credentialRows = rows
            credentialsConfirmed = false
        }
        changeNames = [:]
        environmentNames = [:]
        for repository in review.preflight.repositories {
            for change in repository.executable {
                changeNames[change.id] = SyncCopy.changeName(change)
            }
            for environment in repository.snapshot.environments {
                let name = environment.syncedName ?? environment.name
                environmentNames[RemoteScopeKeyModel.environment(named: name).journalKey] = name
            }
        }
    }

    /// Executable changes across repositories and their destinations.
    var executableCount: Int {
        gitHubExecutableCount + destinationExecutableCount + organizationExecutableCount
    }

    private var organizationExecutableCount: Int {
        organizationReviews.reduce(0) { $0 + $1.changes.count }
    }

    private var gitHubExecutableCount: Int {
        effectiveReview?.preflight.executableCount ?? 0
    }

    private var destinationExecutableCount: Int {
        effectiveDestinationReviews.reduce(0) { $0 + $1.executableCount }
    }

    /// True when every pending change waits for a share file the user has not included.
    var waitsOnlyForHeldShares: Bool {
        executableCount == 0 && !heldShares.isEmpty
    }

    /// Destination and (1.0) organization deletions: they are not in GitHub's live fetch.
    private var destinationDeletionCount: Int {
        destinationReviews.reduce(0) { $0 + $1.deletions.count } + organizationReviews.reduce(0) { $0 + $1.deletions.count }
    }

    /// The "Sync N" count of the sheet (§7.1 pending count of what will run).
    var pendingCount: Int {
        repositories.map(\.pendingCount).reduce(0, +)
    }

    var deletionCount: Int {
        (effectiveReview?.deletionCount ?? 0) + destinationDeletionCount
    }

    /// Executable changes that are not deletions ("Sync Without Deleting" needs one).
    var nonDeletionCount: Int {
        executableCount - deletionCount
    }

    /// "FX Vault write limit this hour: X of 450".
    var writeBudgetLine: String? {
        effectiveReview?.summary.writeBudget.map(SyncCopy.writeBudgetLine)
    }

    /// The run needs more writes than are left this hour.
    var writeBudgetWarning: String? {
        guard let preflight = effectiveReview?.preflight, preflight.exceedsWriteBudget else { return nil }
        return SyncCopy.writeBudgetExceeded(cost: preflight.estimatedWriteCost)
    }

    /// Summary warnings that are not per-change (repository variables size, clone folder).
    var summaryWarnings: [String] {
        guard let review = effectiveReview else { return [] }
        var warnings: [String] = []
        if review.preflight.repositories.contains(where: \.exceedsRepositoryVariablesSize) {
            warnings.append(SyncCopy.repositoryVariablesTooLarge)
        }
        if dependencies.preferences.cloneFolderURL == nil, requestsClone(review) {
            warnings.append(SyncCopy.cloneFolderMissing)
        }
        return warnings
    }

    private func requestsClone(_ review: SyncReviewModel) -> Bool {
        review.preflight.repositories.contains { repository in
            repository.executable.contains { change in
                if case .createRepository(let create) = change.operation { return create.spec?.cloneAfter == true }
                return false
            }
        }
    }

    /// True when the summary may start a run: something to run, credential-looking variables
    /// confirmed, and an internet connection (the sheet may have opened just before the Mac went
    /// offline).
    var canProceed: Bool {
        executableCount > 0 && (credentialRows.isEmpty || credentialsConfirmed) && isOnline
    }

    /// False while the Mac has no internet connection (v0.2.0 connectivity banner).
    var isOnline: Bool {
        dependencies.connectivity.isOnline
    }

    /// The footer note: the offline explanation while the summary or the deletion review cannot
    /// start a run, otherwise the last copy confirmation.
    var footerNotice: String? {
        if !isOnline, step == .summary || step == .deletions {
            return ConnectivityCopy.offlineHelp
        }
        return notice
    }

    // MARK: - Deletions (§7.5)

    /// Summary → Deletions, with the live fetch of every environment being deleted.
    func reviewDeletions() async {
        guard let review = effectiveReview, canProceed, deletionCount > 0 else { return }
        step = .deletions
        deletionsAcknowledged = false
        unknownContentsAcknowledged = false
        deletionPreviews = nil
        deletionPreviews = await service.deletionPreview(for: review)
    }

    /// The deletion review rows; empty while the live fetch runs.
    var deletionRows: [SyncDeletionRepoModel] {
        guard let deletionPreviews else { return [] }
        return DestinationSyncPresentation.mergeDeletions(
            SyncPresentationBuilder.deletions(deletionPreviews),
            with: destinationReviews,
            fullName: fullName(of:)
        ) + OrgSyncPresentation.deletions(organizationReviews)
    }

    /// "Delete N items".
    var deletionTotal: Int {
        (deletionPreviews?.map(\.deletionCount).reduce(0, +)).map { $0 + destinationDeletionCount } ?? deletionCount
    }

    var hasUnknownContents: Bool {
        deletionPreviews?.contains(where: \.hasUnknownContents) ?? false
    }

    /// The confirmed run with deletions is allowed (§7.5).
    var canConfirmDeletions: Bool {
        deletionPreviews != nil && deletionsAcknowledged && (!hasUnknownContents || unknownContentsAcknowledged)
    }

    func backToSummary() {
        guard step == .deletions else { return }
        deletionsAcknowledged = false
        unknownContentsAcknowledged = false
        step = .summary
    }

    // MARK: - Run (§7.3, §7.4)

    /// Starts the run and follows it to the result. Holds a ``SyncActivity`` for the whole run.
    func startSync(includeDeletions: Bool) async {
        guard let review, canProceed, step == .summary || step == .deletions else { return }
        if includeDeletions, !canConfirmDeletions { return }
        if !includeDeletions, nonDeletionCount == 0 { return }
        let activity = dependencies.actions.beginSyncActivity()
        defer { activity.end() }

        progress = SyncRunProgressModel(total: includeDeletions ? executableCount : nonDeletionCount)
        step = .progress
        let included = includedHeldShares
        let gitHubDeletions = effectiveReview?.deletionCount ?? review.deletionCount
        let gitHubCount = includeDeletions ? gitHubExecutableCount : gitHubExecutableCount - gitHubDeletions
        var outcome: SyncRunOutcomeModel?
        if gitHubCount > 0 {
            let run: any SyncRunControlling
            do {
                run = try await service.startRun(
                    review,
                    includeDeletions: includeDeletions,
                    includeHeld: included,
                    cloneFolder: dependencies.preferences.cloneFolderURL
                )
            } catch {
                dependencies.gitHubReachability.record(error)
                alert = error.presentation
                step = .summary
                return
            }
            self.run = run
            for await event in run.progress {
                apply(event)
            }
            outcome = await run.outcome()
            self.run = nil
        }
        let destinationResults = await runDestinations(
            includeDeletions: includeDeletions,
            includeHeld: included,
            after: progress.completed
        )
        let organizationResults = await runOrganizations(includeDeletions: includeDeletions)
        show(outcome, destinationResults: destinationResults, organizationResults: organizationResults)
    }

    /// The organization changes, last (1.0). A cancelled run skips them.
    private func runOrganizations(includeDeletions: Bool) async -> [OrganizationID: OrgRunResultModel] {
        guard !progress.isCancelling else { return [:] }
        var results: [OrganizationID: OrgRunResultModel] = [:]
        for review in organizationReviews where !review.changes.isEmpty {
            progress.phase = .writing
            progress.currentName = review.login
            results[review.organizationID] = await dependencies.organizationSync.run(review, includeDeletions: includeDeletions)
        }
        progress.currentName = nil
        progress.completed = progress.total
        return results
    }

    /// The destination changes, after GitHub's (v0.8.0). A cancelled run skips them. The held
    /// writes of `includeHeld` files run with them (v0.9.0).
    private func runDestinations(
        includeDeletions: Bool,
        includeHeld: Set<SharePackageID>,
        after completed: Int
    ) async -> [DestinationRunResultModel] {
        guard !progress.isCancelling else { return [] }
        let sync = dependencies.destinationSync
        var results: [DestinationRunResultModel] = []
        let effective = effectiveDestinationReviews
        let names = Dictionary(
            effective.flatMap { $0.sections.flatMap(\.changes) }.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        progress.completed = completed
        for (review, effectiveReview) in zip(destinationReviews, effective) where effectiveReview.executableCount > 0 {
            progress.phase = .writing
            let result = await sync.run(review, includeDeletions: includeDeletions, includeHeld: includeHeld) { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch event {
                    case .started(let id):
                        progress.currentName = names[id]
                    case .finished:
                        progress.completed = min(progress.total, progress.completed + 1)
                    }
                }
            }
            results.append(result)
        }
        progress.currentName = nil
        progress.completed = progress.total
        return results
    }

    private func apply(_ event: SyncProgressEventModel) {
        switch event {
        case .started(let total):
            progress.total = total
            progress.phase = .writing
        case .changeStarted(let changeID):
            progress.currentName = changeNames[changeID]
            progress.phase = .writing
        case .changeFinished(_, let completed, let total):
            progress.completed = completed
            progress.total = total
        case .verifying(let scope):
            progress.phase = .verifying(scope: scopeLabel(scope))
        case .finished(let result):
            progress.currentName = nil
            progress.completed = progress.total
            let requestsClone = result.warnings.contains { if case .cloneRequested = $0 { true } else { false } }
            if requestsClone, dependencies.preferences.cloneFolderURL != nil {
                progress.phase = .cloning
            }
        }
    }

    private func scopeLabel(_ scope: RemoteScopeKeyModel) -> String {
        guard scope.environmentKey != nil else { return SyncCopy.scopeLabel(.repository) }
        return environmentNames[scope.journalKey] ?? scope.environmentKey ?? ""
    }

    /// Cancel: stops after the gh command in flight (§7.4). Completed items stay synced.
    func cancelRun() {
        guard step == .progress, let run else { return }
        progress.isCancelling = true
        run.cancel()
    }

    private func show(
        _ outcome: SyncRunOutcomeModel?,
        destinationResults: [DestinationRunResultModel],
        organizationResults: [OrganizationID: OrgRunResultModel]
    ) {
        self.outcome = outcome
        var sections = outcome.map { SyncPresentationBuilder.resultSections($0.result, repositories: repositoryModels) } ?? []
        let extraRows = [
            DestinationSyncPresentation.resultRows(destinationResults, reviews: effectiveDestinationReviews),
            OrgSyncPresentation.resultRows(organizationResults, reviews: organizationReviews),
        ]
        for rowsByKind in extraRows {
            for kind in SyncResultSectionModel.Kind.allCases {
                guard let rows = rowsByKind[kind], !rows.isEmpty else { continue }
                if let index = sections.firstIndex(where: { $0.kind == kind }) {
                    sections[index] = SyncResultSectionModel(kind: kind, rows: sections[index].rows + rows)
                } else {
                    sections.append(SyncResultSectionModel(kind: kind, rows: rows))
                }
            }
        }
        resultSections = sections.sorted { lhs, rhs in
            (SyncResultSectionModel.Kind.allCases.firstIndex(of: lhs.kind) ?? 0)
                < (SyncResultSectionModel.Kind.allCases.firstIndex(of: rhs.kind) ?? 0)
        }
        clones = outcome?.clones.map { clone in
            SyncCloneRowModel(id: clone.repositoryID, fullName: fullName(of: clone.repositoryID), state: cloneState(clone.state))
        } ?? []
        step = .result
        if let outcome {
            reportReachability(outcome.result)
            AppLog.ui.info(
                """
                Sync finished: \(outcome.result.succeeded.count, privacy: .public) succeeded, \
                \(outcome.result.failed.count, privacy: .public) failed, \(outcome.result.skipped.count, privacy: .public) skipped, \
                \(outcome.result.blocked.count, privacy: .public) blocked
                """
            )
            requestRefresh(after: outcome.result)
        }
    }

    /// Reports the run to `GitHubReachability`: the last change that says anything about GitHub
    /// decides (a success or an error GitHub returned means it answered; a network failure or
    /// timeout means it did not).
    private func reportReachability(_ result: SyncResultModel) {
        let last = result.entries.last { entry in
            switch entry.outcome {
            case .succeeded: true
            case .failed(.github(let error)): error.reachedGitHub != nil
            case .failed, .skipped, .blocked: false
            }
        }
        if case .failed(.github(let error)) = last?.outcome {
            dependencies.gitHubReachability.record(error)
        } else if last != nil {
            dependencies.gitHubReachability.recordSuccess()
        }
    }

    /// gh-backed data the database observation does not cover: drift of every synced
    /// repository, and the catalog when a repository was created.
    private func requestRefresh(after result: SyncResultModel) {
        guard !didRequestRefresh else { return }
        didRequestRefresh = true
        let created = result.succeeded.contains { $0.change.kind == .createRepository }
        if created {
            dependencies.actions.refresh(.catalog)
        }
        for repository in result.repositories where repository.entries.contains(where: \.outcome.isSucceeded) {
            dependencies.actions.refresh(.drift(repository.repositoryID))
        }
    }

    private func cloneState(_ state: RepoCloneOutcomeModel.State) -> SyncCloneRowModel.State {
        switch state {
        case .cloned(let url): .cloned(path: url.path)
        case .failed(let error): .failed(error.presentation.message)
        case .notAttempted: .notAttempted
        }
    }

    /// nil: the Key Vaults of their own.
    private func fullName(of id: RepoID?) -> String {
        guard let id else { return MainCopy.azureSection }
        return repositoryModels[id]?.fullName ?? (try? dependencies.config.changeSet(repositoryID: id))??.repository.fullName ?? ""
    }

    /// The stop reason line, when the run stopped early.
    var stopReason: SyncIssueModel? {
        guard let stop = outcome?.result.stopReason else { return nil }
        return SyncIssueModel(
            id: "stop",
            title: String(localized: "sync.result.stopped", defaultValue: "The sync stopped early"),
            reason: SyncCopy.stopReason(stop),
            fix: SyncPresentationBuilder.fix(for: stop)
        )
    }

    var warnings: [String] {
        outcome?.result.warnings.compactMap(SyncCopy.warning) ?? []
    }

    /// The fix of a clone row: Clone (again). Without a clone folder it asks for one first.
    func cloneFix(_ row: SyncCloneRowModel) -> SyncFixActionModel? {
        switch row.state {
        case .failed, .notAttempted:
            .clone(row.id)
        case .cloning, .cloned:
            nil
        }
    }

    /// Clones a repository the run created (§7.3 step 8) with a busy state. Asks for a clone
    /// folder when Preferences has none; does nothing when that is cancelled.
    func clone(_ repositoryID: RepoID) async {
        guard clones.contains(where: { $0.id == repositoryID }),
              let folder = dependencies.preferences.cloneFolderURL ?? chooseCloneFolder(),
              let index = clones.firstIndex(where: { $0.id == repositoryID })
        else { return }
        clones[index].state = .cloning
        let state: SyncCloneRowModel.State
        do {
            let url = try await service.clone(repositoryID, into: folder)
            state = .cloned(path: url.path)
        } catch {
            state = .failed(error.presentation.message)
        }
        if let index = clones.firstIndex(where: { $0.id == repositoryID }) {
            clones[index].state = state
        }
    }

    // MARK: - Fixes

    func perform(_ fix: SyncFixActionModel) {
        switch fix {
        case .fillValue(let context), .editItem(let context), .convertToSecret(let context):
            dependencies.actions.present(.itemEditor(context))
        case .reviewDrift(let repositoryID):
            dependencies.actions.present(.driftReview(DriftReviewContext(repositoryID: repositoryID)))
        case .askAdmin(let request):
            dependencies.clipboard.copyCommand(request)
            notice = SyncCopy.adminRequestCopied
        case .runInTerminal(let command):
            dependencies.clipboard.copyCommand(command)
            notice = SyncCopy.commandCopied
        case .authorizeSAML(let url), .learnMore(let url):
            openURL(url)
        case .clone(let repositoryID):
            Task { await clone(repositoryID) }
        case .openDestination(let destinationID):
            dependencies.actions.openPlace(.destination(destinationID))
        case .editOrganizationItem(let context):
            dependencies.actions.present(.orgItemEditor(context))
        }
    }

    // MARK: - Copyable text (names only)

    /// The summary as plain text, for a pull request or a message. Names and counts only.
    var summaryText: String {
        var lines: [String] = []
        for repository in repositories {
            lines.append(repository.newRepository.map { "\(repository.fullName)   (\($0))" } ?? repository.fullName)
            for scope in repository.scopes {
                lines.append("  " + ([scope.sentence] + scope.details).joined(separator: "   "))
            }
            for issue in repository.blocked + repository.remoteChanged {
                lines.append("  \(issue.title): \(issue.reason)")
            }
            lines += repository.notes.map { "  \($0)" }
        }
        if let writeBudgetLine {
            lines.append(writeBudgetLine)
        }
        return lines.joined(separator: "\n")
    }

    /// The result as plain text. Names and reasons only.
    var resultText: String {
        var lines: [String] = []
        if let stopReason {
            lines.append(stopReason.reason)
        }
        for section in resultSections {
            lines.append(section.kind.title)
            lines += section.rows.map { "  \($0.title): \($0.reason)" }
        }
        lines += warnings
        return lines.joined(separator: "\n")
    }

    func copySummary() {
        dependencies.clipboard.copyCommand(step == .result ? resultText : summaryText)
        notice = SyncCopy.reportCopied
    }

    // MARK: - Footer (§7.5 default-button rules)

    var buttons: [SyncButtonModel] {
        switch step {
        case .loading:
            [SyncButtonModel(action: .close, title: Self.cancelTitle, isCancel: true)]
        case .failed:
            [
                SyncButtonModel(action: .close, title: Self.closeTitle, isCancel: true),
                SyncButtonModel(
                    action: .retry,
                    title: String(localized: "sync.button.retry", defaultValue: "Try Again"),
                    isDefault: true
                ),
            ]
        case .summary:
            [SyncButtonModel(action: .close, title: Self.cancelTitle, isCancel: true), summaryPrimaryButton]
        case .deletions:
            [
                SyncButtonModel(
                    action: .back,
                    title: String(localized: "sync.button.back", defaultValue: "Back"),
                    isCancel: true
                ),
                SyncButtonModel(
                    action: .syncWithoutDeleting,
                    title: String(localized: "sync.button.syncWithoutDeleting", defaultValue: "Sync Without Deleting"),
                    isEnabled: nonDeletionCount > 0 && deletionPreviews != nil
                ),
                SyncButtonModel(
                    action: .confirmDeletions,
                    title: String(
                        localized: "sync.button.confirmDeletions",
                        defaultValue: "Delete \(deletionTotal) Items on GitHub"
                    ),
                    isDestructive: true,
                    isEnabled: canConfirmDeletions
                ),
            ]
        case .progress:
            [
                SyncButtonModel(
                    action: .cancelRun,
                    title: progress.isCancelling
                        ? String(localized: "sync.button.cancelling", defaultValue: "Cancelling…")
                        : Self.cancelTitle,
                    isEnabled: !progress.isCancelling && progress.phase != .cloning
                ),
            ]
        case .result:
            [SyncButtonModel(action: .done, title: String(localized: "common.done", defaultValue: "Done"), isDefault: true)]
        }
    }

    private var summaryPrimaryButton: SyncButtonModel {
        if deletionCount > 0 {
            return SyncButtonModel(
                action: .reviewDeletions,
                // Automatic grammar agreement: "Review 1 Deletion…", "Review 2 Deletions…".
                title: String(AttributedString(
                    localized: "sync.button.reviewDeletions",
                    defaultValue: "Review ^[\(deletionCount) Deletion](inflect: true)…"
                ).characters),
                isDefault: true,
                isEnabled: canProceed
            )
        }
        return SyncButtonModel(
            action: .sync,
            title: pendingCount > 0
                ? String(localized: "sync.button.syncCount", defaultValue: "Sync \(pendingCount)")
                : String(localized: "sync.button.sync", defaultValue: "Sync"),
            isDefault: true,
            isEnabled: canProceed
        )
    }

    private static let cancelTitle = String(localized: "common.cancel", defaultValue: "Cancel")
    private static let closeTitle = String(localized: "common.close", defaultValue: "Close")

    /// Runs a footer action. Returns true when the sheet should close.
    @discardableResult
    func perform(_ action: SyncButtonAction) -> Bool {
        switch action {
        case .close, .done:
            return true
        case .retry:
            Task { await load() }
        case .reviewDeletions:
            Task { await reviewDeletions() }
        case .sync:
            Task { await startSync(includeDeletions: false) }
        case .back:
            backToSummary()
        case .syncWithoutDeleting:
            Task { await startSync(includeDeletions: false) }
        case .confirmDeletions:
            Task { await startSync(includeDeletions: true) }
        case .cancelRun:
            cancelRun()
        }
        return false
    }

    /// True while the sheet must not be dismissed by Escape or a click outside (the run).
    var blocksDismissal: Bool {
        step == .progress
    }

    // MARK: - LockObserving

    func vaultDidLock() {
        run?.cancel()
    }
}

extension SyncResultSectionModel.Kind {
    var title: String {
        switch self {
        case .succeeded: String(localized: "sync.result.succeeded", defaultValue: "Succeeded")
        case .failed: String(localized: "sync.result.failed", defaultValue: "Failed")
        case .skipped: String(localized: "sync.result.skipped", defaultValue: "Skipped")
        case .blocked: String(localized: "sync.result.blocked", defaultValue: "Blocked")
        }
    }
}
