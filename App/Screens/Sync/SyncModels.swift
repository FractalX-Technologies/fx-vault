import Foundation
import GitHubKit
import SyncEngine
import VaultCore
import VaultData

/// The steps of the Sync sheet (§10 Sheets): Summary → Deletions → Progress → Result.
enum SyncSheetStepModel: Equatable {
    /// Preflight is running.
    case loading
    /// Preflight failed as a whole (locked, gh missing, journal failure).
    case failed(ErrorPresentationModel)
    case summary
    /// §7.5, only when the run deletes something.
    case deletions
    case progress
    case result
}

/// What a footer button does.
enum SyncButtonAction: Hashable {
    /// Close the sheet without syncing.
    case close
    /// Run preflight again after a failure.
    case retry
    /// Summary → Deletions (§7.5 "Review N deletions…").
    case reviewDeletions
    /// Summary → Progress, nothing to delete.
    case sync
    /// Deletions → Summary.
    case back
    /// Run everything except the deletions.
    case syncWithoutDeleting
    /// Run with the deletions (needs "I understand this cannot be undone").
    case confirmDeletions
    /// Stop the run after the gh command in flight.
    case cancelRun
    /// Close the result.
    case done
}

/// One footer button. The view renders exactly these, so the default-button rules (§7.5:
/// neither deletion button is the default and Return does nothing) are view-model state.
struct SyncButtonModel: Identifiable, Hashable {
    let action: SyncButtonAction
    let title: String
    /// Bound to Return (`.defaultAction`) and drawn prominent.
    var isDefault = false
    /// Bound to Escape (`.cancelAction`).
    var isCancel = false
    var isDestructive = false
    var isEnabled = true

    var id: SyncButtonAction {
        action
    }
}

/// A fix offered next to a blocked or failed change (§7.4).
enum SyncFixActionModel: Hashable {
    /// A value-missing secret: the item editor in fill mode.
    case fillValue(ItemEditorContext)
    /// An invalid name or value: the item editor.
    case editItem(ItemEditorContext)
    /// A credential-looking variable (§5.13): Convert/Move to a secret.
    case convertToSecret(ItemEditorContext)
    /// Changed on GitHub (D27): the drift review of the repository.
    case reviewDrift(RepoID)
    /// Admin required: copy a request to send to an admin.
    case askAdmin(request: String)
    /// SAML: open the authorization link gh printed.
    case authorizeSAML(URL)
    /// Token revoked, missing scopes, not logged in: copy the command to run in Terminal.
    case runInTerminal(command: String)
    /// Plan-gated (and SAML without a link): the GitHub documentation.
    case learnMore(URL)
    /// Clone a repository the run created (retry, or after a clone folder was chosen).
    case clone(RepoID)
    /// A destination change needs a Refresh, a connection or its settings (v0.8.0): show the
    /// destination.
    case openDestination(DestinationID)
}

/// One line of the summary, the deletion review or the result: a title (names only), the
/// localized reason, and an optional fix.
struct SyncIssueModel: Identifiable, Hashable {
    let id: String
    let title: String
    let reason: String
    var fix: SyncFixActionModel?
}

/// One scope line of the summary: "2 added, 1 modified in production" plus its item names.
struct SyncSummaryScopeModel: Identifiable, Hashable {
    let id: String
    let title: String
    let sentence: String
    let details: [String]
}

/// One repository of the summary (§7.2).
struct SyncSummaryRepoModel: Identifiable, Hashable {
    let id: RepoID
    let fullName: String
    /// "New repository · Private · README · MIT" when the run creates it.
    let newRepository: String?
    let scopes: [SyncSummaryScopeModel]
    /// Blocked changes with their reason and fix (dependents folded into ``dependentCount``).
    let blocked: [SyncIssueModel]
    /// Changes waiting only because another change is blocked.
    let dependentCount: Int
    /// Changed on GitHub since the last check (D27), routed to Drift review.
    let remoteChanged: [SyncIssueModel]
    let notes: [String]
    /// Executable changes of this repository.
    let pendingCount: Int

    /// False when the summary has nothing to say about this repository (every change waits for
    /// a share file, v0.9.0): the block is left out.
    var hasContent: Bool {
        newRepository != nil || !scopes.isEmpty || !blocked.isEmpty || !remoteChanged.isEmpty || !notes.isEmpty || dependentCount > 0
    }
}

/// A variable that looks like a credential (§5.13): names and reasons only.
struct SyncCredentialRowModel: Identifiable, Hashable {
    let id: String
    let title: String
    let reasons: String
    let fix: SyncFixActionModel
}

/// The progress step (§10 Sheets: n of m, current item, Cancel).
struct SyncRunProgressModel: Equatable {
    enum Phase: Equatable {
        case starting
        case writing
        /// Re-listing a scope to confirm its writes.
        case verifying(scope: String)
        /// Cloning the repositories the run created.
        case cloning
    }

    var completed = 0
    var total = 0
    /// The change in flight (name only).
    var currentName: String?
    var phase: Phase = .starting
    var isCancelling = false

    var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}

/// One section of the result (§7.4).
struct SyncResultSectionModel: Identifiable, Hashable {
    enum Kind: String, Hashable, CaseIterable {
        case failed
        case blocked
        case skipped
        case succeeded
    }

    let kind: Kind
    let rows: [SyncIssueModel]

    var id: Kind {
        kind
    }
}

/// What happened to a clone the run requested.
struct SyncCloneRowModel: Identifiable, Hashable {
    enum State: Hashable {
        case cloning
        case cloned(path: String)
        case failed(String)
        /// No clone folder was set.
        case notAttempted
    }

    let id: RepoID
    let fullName: String
    var state: State
}

// MARK: - Builders (pure)

/// Turns SyncEngine and VaultData models into the sheet's rows. Pure and value-free: every
/// input carries names, kinds and counts only.
enum SyncPresentationBuilder {
    /// The summary of every repository in the review, in review order.
    static func summary(_ review: SyncReviewModel) -> [SyncSummaryRepoModel] {
        review.preflight.repositories.map(repository)
    }

    static func repository(_ preflight: RepoPreflightModel) -> SyncSummaryRepoModel {
        let repository = preflight.snapshot.repository
        // Summarize only what will run: preflight's own blocks (capability, names, values,
        // capacity) are not in the change set, so the scope counts would include them.
        let executable = ChangeSetModel(repository: repository, changes: preflight.executable, notes: preflight.changeSet.notes)
        let summary = ChangeSummaryBuilder.summarize(executable)
        let scopes = summary.scopes.map { scope in
            SyncSummaryScopeModel(
                id: scope.scope.journalKey,
                title: SyncCopy.scopeTitle(scope),
                sentence: SyncCopy.scopeSentence(scope),
                details: (scope.policy.map { [SyncCopy.policyLine($0)] } ?? []) + scope.items.map(SyncCopy.itemLine)
            )
        }
        var blocked: [SyncIssueModel] = []
        var remoteChanged: [SyncIssueModel] = []
        var dependentCount = 0
        for entry in preflight.blocked {
            let issue = SyncIssueModel(
                id: entry.change.id,
                title: SyncCopy.changeTitle(entry.change),
                reason: SyncCopy.blockReason(entry.reason),
                fix: renameFill(entry, snapshot: preflight.snapshot)
                    ?? fix(for: entry.reason, change: entry.change, repository: repository)
            )
            switch entry.reason {
            case .dependsOn, .change(.dependsOn):
                dependentCount += 1
            case .change(.remoteChanged):
                remoteChanged.append(issue)
            default:
                blocked.append(issue)
            }
        }
        return SyncSummaryRepoModel(
            id: repository.id,
            fullName: repository.fullName,
            newRepository: summary.newRepository.map(SyncCopy.newRepositoryLine),
            scopes: scopes,
            blocked: blocked,
            dependentCount: dependentCount,
            remoteChanged: remoteChanged,
            notes: summary.notes.map(SyncCopy.note),
            pendingCount: summary.pendingCount
        )
    }

    static func credentialRows(_ review: SyncReviewModel) -> [SyncCredentialRowModel] {
        review.credentialWarnings.map { warning in
            let scope = SyncCopy.scopeLabel(environmentName: warning.environmentName)
            let editorScope = environmentScope(warning.itemID, review: review)
            return SyncCredentialRowModel(
                id: warning.id,
                title: String(localized: "sync.credential.title", defaultValue: "\(warning.name) in \(scope)"),
                reasons: warning.reasons.map(SyncCopy.credentialReason)
                    .joined(separator: String(localized: "sync.list.separator", defaultValue: ", ")),
                fix: .convertToSecret(ItemEditorContext(
                    repositoryID: warning.repositoryID,
                    scope: editorScope,
                    mode: .move(warning.itemID)
                ))
            )
        }
    }

    /// The result sections in the order the user acts on them: Failed, Blocked, Skipped,
    /// Succeeded. Empty sections are left out.
    static func resultSections(_ result: SyncResultModel, repositories: [RepoID: RepoModel]) -> [SyncResultSectionModel] {
        var rows: [SyncResultSectionModel.Kind: [SyncIssueModel]] = [:]
        let showsRepository = result.repositories.count > 1
        for repositoryResult in result.repositories {
            let repository = repositories[repositoryResult.repositoryID]
            for entry in repositoryResult.entries {
                let kind: SyncResultSectionModel.Kind
                let reason: String
                var fix: SyncFixActionModel?
                switch entry.outcome {
                case .succeeded(let state):
                    kind = .succeeded
                    reason = SyncCopy.verification(state)
                case .failed(let failure):
                    kind = .failed
                    reason = SyncCopy.failureReason(failure)
                    fix = Self.fix(for: failure, change: entry.change, repository: repository)
                case .skipped(let skip):
                    kind = .skipped
                    reason = SyncCopy.skipReason(skip)
                case .blocked(let block):
                    kind = .blocked
                    reason = SyncCopy.blockReason(block)
                    fix = Self.fix(for: block, change: entry.change, repository: repository)
                }
                let title = showsRepository
                    ? String(
                        localized: "sync.result.rowWithRepository",
                        defaultValue: "\(SyncCopy.changeTitle(entry.change)) (\(repositoryResult.fullName))"
                    )
                    : SyncCopy.changeTitle(entry.change)
                rows[kind, default: []].append(SyncIssueModel(
                    id: repositoryResult.repositoryID.uuidString + entry.id,
                    title: title,
                    reason: reason,
                    fix: fix
                ))
            }
        }
        return SyncResultSectionModel.Kind.allCases.compactMap { kind in
            rows[kind].map { SyncResultSectionModel(kind: kind, rows: $0) }
        }
    }

    // MARK: - Fixes (§7.4)

    static func fix(for reason: SyncBlockReason, change: ConfigChangeModel, repository: RepoModel?) -> SyncFixActionModel? {
        switch reason {
        case .change(.valueMissing):
            return editorContext(change, mode: ItemEditorContext.Mode.fill).map(SyncFixActionModel.fillValue)
        case .change(.remoteChanged):
            return .reviewDrift(change.repositoryID)
        case .change(.renameNeedsValues), .change(.dependsOn), .dependsOn, .scopeFull, .readOnly(.archived), .protectionRulesPresent:
            return nil
        case .readOnly(.adminRequired), .readOnly(.unavailable):
            return repository.map(askAdmin)
        case .missingScopes:
            guard let repository else { return nil }
            let commands = ScopeChecker.fixCommands(login: repository.accountLogin, previousActiveLogin: nil)
            return .runInTerminal(command: commands.joined(separator: " && "))
        case .invalidName, .invalidValue:
            return editorContext(change, mode: ItemEditorContext.Mode.edit).map(SyncFixActionModel.editItem)
        case .listingFailed(let error):
            return fix(for: error, repository: repository)
        }
    }

    static func fix(for reason: SyncFailureReason, change: ConfigChangeModel, repository: RepoModel?) -> SyncFixActionModel? {
        switch reason {
        case .github(let error):
            fix(for: error, repository: repository)
        case .valueMissing:
            editorContext(change, mode: ItemEditorContext.Mode.fill).map(SyncFixActionModel.fillValue)
        case .invalidValue:
            editorContext(change, mode: ItemEditorContext.Mode.edit).map(SyncFixActionModel.editItem)
        case .indeterminate, .renameTargetIsSource, .renameNotVerified, .createConflict, .locked:
            nil
        }
    }

    static func fix(for error: GHError, repository: RepoModel?) -> SyncFixActionModel? {
        switch error {
        case .adminRequired, .writeAccessRequired:
            repository.map(askAdmin)
        case .samlRequired(let url):
            if let url {
                .authorizeSAML(url)
            } else {
                ExternalLinks.samlSingleSignOn.map(SyncFixActionModel.learnMore)
            }
        case .planGated:
            ExternalLinks.environmentPlans.map(SyncFixActionModel.learnMore)
        case .tokenRevoked, .notAuthenticated:
            .runInTerminal(command: GHSetupViewModel.loginCommand)
        case .missingScopes:
            repository.map { repository in
                .runInTerminal(command: ScopeChecker.fixCommands(login: repository.accountLogin, previousActiveLogin: nil)
                    .joined(separator: " && "))
            }
        default:
            nil
        }
    }

    static func fix(for stop: SyncStopReason) -> SyncFixActionModel? {
        switch stop {
        case .tokenRevoked, .notAuthenticated:
            .runInTerminal(command: GHSetupViewModel.loginCommand)
        case .rateLimited, .writeBudgetExhausted, .cancelled, .locked, .persistenceFailed:
            nil
        }
    }

    /// §7.6 "Enter values": a guided rename blocked on value-missing secrets opens the first of
    /// them in fill mode.
    private static func renameFill(_ entry: SyncBlockedChangeModel, snapshot: RepoSnapshotModel) -> SyncFixActionModel? {
        guard case .change(.renameNeedsValues(let names)) = entry.reason,
              case .renameEnvironment(let rename) = entry.change.operation
        else { return nil }
        let scope = ConfigScope.environment(rename.environmentID)
        let keys = Set(names.map(GitHubNameValidator.foldKey))
        let missing = snapshot.items(in: scope).first { item in
            !item.isDeleted && !item.hasValue && keys.contains(GitHubNameValidator.foldKey(item.name))
        }
        return missing.map { item in
            .fillValue(ItemEditorContext(repositoryID: entry.change.repositoryID, scope: scope, mode: .fill(item.id)))
        }
    }

    private static func askAdmin(_ repository: RepoModel) -> SyncFixActionModel {
        .askAdmin(request: SyncCopy.adminRequest(login: repository.accountLogin, fullName: repository.fullName))
    }

    /// The item editor context of an item change, or nil for other changes.
    private static func editorContext(
        _ change: ConfigChangeModel,
        mode: (ConfigItemID) -> ItemEditorContext.Mode
    ) -> ItemEditorContext? {
        switch change.operation {
        case .setItem(let set):
            ItemEditorContext(
                repositoryID: change.repositoryID,
                scope: ConfigScope(environmentID: set.environmentID),
                mode: mode(set.itemID)
            )
        case .deleteItem(let delete):
            ItemEditorContext(
                repositoryID: change.repositoryID,
                scope: ConfigScope(environmentID: delete.environmentID),
                mode: mode(delete.itemID)
            )
        default:
            nil
        }
    }

    /// The local scope of an item the review is about to push.
    private static func environmentScope(_ itemID: ConfigItemID, review: SyncReviewModel) -> ConfigScope {
        for repository in review.preflight.repositories {
            for change in repository.executable {
                if case .setItem(let set) = change.operation, set.itemID == itemID {
                    return ConfigScope(environmentID: set.environmentID)
                }
            }
        }
        return .repository
    }
}

// MARK: - Deletion review (§7.5)

/// One name in an environment being deleted.
struct SyncDeletionItemModel: Identifiable, Hashable {
    let id: String
    /// "API_TOKEN (secret)".
    let title: String
    /// GitHub has it and the vault does not: "not in your vault: will be lost".
    let willBeLost: Bool
}

/// One environment being deleted, with its live contents.
struct SyncDeletionEnvironmentModel: Identifiable, Hashable {
    enum Contents: Hashable {
        /// `foreignRules`: the other protection rules GitHub lists (reviewers, wait timer, app
        /// rules), deleted with the environment.
        case loaded(items: [SyncDeletionItemModel], patterns: String?, foreignRules: [String])
        /// GitHub no longer has it; the delete only confirms that.
        case alreadyDeleted
        /// The fetch failed: "contents unknown" with the reason.
        case unknown(reason: String)
    }

    let id: String
    let name: String
    let contents: Contents

    var lostCount: Int {
        guard case .loaded(let items, _, _) = contents else { return 0 }
        return items.filter(\.willBeLost).count
    }
}

/// One repository's deletions.
struct SyncDeletionRepoModel: Identifiable, Hashable {
    let id: RepoID
    let fullName: String
    /// Item deletions: "Delete secret OLD_TOKEN in Repository".
    let items: [SyncIssueModel]
    let environments: [SyncDeletionEnvironmentModel]
}

extension SyncPresentationBuilder {
    static func deletions(_ previews: [RepoDeletionPreviewModel]) -> [SyncDeletionRepoModel] {
        previews.map { preview in
            SyncDeletionRepoModel(
                id: preview.repositoryID,
                fullName: preview.fullName,
                items: preview.itemDeletions.map { change in
                    SyncIssueModel(id: change.id, title: SyncCopy.changeTitle(change), reason: "")
                },
                environments: preview.environments.map(environment)
            )
        }
    }

    private static func environment(_ preview: EnvironmentDeletionPreviewModel) -> SyncDeletionEnvironmentModel {
        let contents: SyncDeletionEnvironmentModel.Contents
        switch preview.contents {
        case .loaded(let model):
            let items = model.items.map { item in
                SyncDeletionItemModel(
                    id: "\(item.kind.rawValue)|\(item.name)",
                    title: String(
                        localized: "sync.deletions.item",
                        defaultValue: "\(item.name) (\(SyncCopy.kindTitle(item.kind)))"
                    ),
                    willBeLost: item.isRemoteOnly
                )
            }
            let patterns = model.policy == .custom && !model.patterns.isEmpty
                ? model.patterns.joined(separator: String(localized: "sync.list.separator", defaultValue: ", "))
                : nil
            contents = .loaded(items: items, patterns: patterns, foreignRules: foreignRules(model.foreignRulesJSON))
        case .alreadyDeleted:
            contents = .alreadyDeleted
        case .unknown(let error):
            contents = .unknown(reason: error.localizedMessage)
        }
        return SyncDeletionEnvironmentModel(id: preview.id, name: preview.name, contents: contents)
    }

    /// The rule types of GitHub's `protection_rules` (other than the branch policy), named for
    /// display. Unknown types are shown as GitHub names them.
    static func foreignRules(_ json: String?) -> [String] {
        guard let json else { return [] }
        let rules = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
        let types = rules.compactMap { $0[ForeignRuleType.key] as? String }
        guard !types.isEmpty else {
            return [String(localized: "sync.deletions.foreignRule.other", defaultValue: "other protection rules")]
        }
        return types.map(ForeignRuleType.title)
    }

    private enum ForeignRuleType {
        static let key = "type"

        static func title(_ type: String) -> String {
            switch type {
            case "required_reviewers":
                String(localized: "sync.deletions.foreignRule.reviewers", defaultValue: "required reviewers")
            case "wait_timer":
                String(localized: "sync.deletions.foreignRule.waitTimer", defaultValue: "wait timer")
            default:
                type.replacingOccurrences(of: "_", with: " ")
            }
        }
    }
}
