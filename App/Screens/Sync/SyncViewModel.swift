import AppKit
import Foundation
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
            apply(review)
            step = .summary
        } catch {
            step = .failed(error.presentation)
        }
    }

    private func apply(_ review: SyncReviewModel) {
        self.review = review
        repositories = SyncPresentationBuilder.summary(review)
        credentialRows = SyncPresentationBuilder.credentialRows(review)
        credentialsConfirmed = false
        deletionPreviews = nil
        deletionsAcknowledged = false
        unknownContentsAcknowledged = false
        repositoryModels = [:]
        changeNames = [:]
        environmentNames = [:]
        for repository in review.preflight.repositories {
            repositoryModels[repository.id] = repository.snapshot.repository
            for change in repository.executable {
                changeNames[change.id] = SyncCopy.changeName(change)
            }
            for environment in repository.snapshot.environments {
                let name = environment.syncedName ?? environment.name
                environmentNames[RemoteScopeKeyModel.environment(named: name).journalKey] = name
            }
        }
        AppLog.ui.info(
            "Sync review: \(review.preflight.executableCount, privacy: .public) executable, \(review.deletionCount, privacy: .public) deletions"
        )
    }

    /// Executable changes across repositories.
    var executableCount: Int {
        review?.preflight.executableCount ?? 0
    }

    /// The "Sync N" count of the sheet (§7.1 pending count of what will run).
    var pendingCount: Int {
        repositories.map(\.pendingCount).reduce(0, +)
    }

    var deletionCount: Int {
        review?.deletionCount ?? 0
    }

    /// Executable changes that are not deletions ("Sync Without Deleting" needs one).
    var nonDeletionCount: Int {
        executableCount - deletionCount
    }

    /// "FX Vault write limit this hour: X of 450".
    var writeBudgetLine: String? {
        review?.summary.writeBudget.map(SyncCopy.writeBudgetLine)
    }

    /// The run needs more writes than are left this hour.
    var writeBudgetWarning: String? {
        guard let preflight = review?.preflight, preflight.exceedsWriteBudget else { return nil }
        return SyncCopy.writeBudgetExceeded(cost: preflight.estimatedWriteCost)
    }

    /// Summary warnings that are not per-change (repository variables size, clone folder).
    var summaryWarnings: [String] {
        guard let review else { return [] }
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

    /// True when the summary may start a run: something to run, and credential-looking
    /// variables confirmed.
    var canProceed: Bool {
        executableCount > 0 && (credentialRows.isEmpty || credentialsConfirmed)
    }

    // MARK: - Deletions (§7.5)

    /// Summary → Deletions, with the live fetch of every environment being deleted.
    func reviewDeletions() async {
        guard let review, canProceed, deletionCount > 0 else { return }
        step = .deletions
        deletionsAcknowledged = false
        unknownContentsAcknowledged = false
        deletionPreviews = nil
        deletionPreviews = await service.deletionPreview(for: review)
    }

    /// The deletion review rows; empty while the live fetch runs.
    var deletionRows: [SyncDeletionRepoModel] {
        deletionPreviews.map(SyncPresentationBuilder.deletions) ?? []
    }

    /// "Delete N items on GitHub".
    var deletionTotal: Int {
        deletionPreviews?.map(\.deletionCount).reduce(0, +) ?? deletionCount
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
        let run: any SyncRunControlling
        do {
            run = try await service.startRun(
                review,
                includeDeletions: includeDeletions,
                cloneFolder: dependencies.preferences.cloneFolderURL
            )
        } catch {
            alert = error.presentation
            step = .summary
            return
        }
        self.run = run
        for await event in run.progress {
            apply(event)
        }
        let outcome = await run.outcome()
        self.run = nil
        show(outcome)
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

    private func show(_ outcome: SyncRunOutcomeModel) {
        self.outcome = outcome
        resultSections = SyncPresentationBuilder.resultSections(outcome.result, repositories: repositoryModels)
        clones = outcome.clones.map { clone in
            SyncCloneRowModel(id: clone.repositoryID, fullName: fullName(of: clone.repositoryID), state: cloneState(clone.state))
        }
        step = .result
        AppLog.ui.info(
            """
            Sync finished: \(outcome.result.succeeded.count, privacy: .public) succeeded, \
            \(outcome.result.failed.count, privacy: .public) failed, \(outcome.result.skipped.count, privacy: .public) skipped, \
            \(outcome.result.blocked.count, privacy: .public) blocked
            """
        )
        requestRefresh(after: outcome.result)
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

    private func fullName(of id: RepoID) -> String {
        repositoryModels[id]?.fullName ?? ""
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
                title: String(localized: "sync.button.reviewDeletions", defaultValue: "Review \(deletionCount) Deletions…"),
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
