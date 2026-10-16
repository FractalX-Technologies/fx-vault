import EnvTools
import Foundation
import GitHubKit
import SyncEngine
import VaultCore
import VaultData

/// Every user-facing phrase of the Sync sheet (§7.2, §7.4, §7.5). Names, kinds and counts only:
/// nothing here ever receives a value.
nonisolated enum SyncCopy {
    // MARK: - Scopes and items

    static func scopeLabel(_ label: ScopeLabelModel) -> String {
        switch label {
        case .repository:
            String(localized: "sync.scope.repository", defaultValue: "Repository")
        case .environment(let name):
            name
        }
    }

    /// The scope of an item change: "Repository" or the environment name.
    static func scopeLabel(environmentName: String?) -> String {
        scopeLabel(environmentName.map(ScopeLabelModel.environment) ?? .repository)
    }

    static func kindTitle(_ kind: ConfigKind) -> String {
        switch kind {
        case .secret: String(localized: "sync.kind.secret", defaultValue: "secret")
        case .variable: String(localized: "sync.kind.variable", defaultValue: "variable")
        }
    }

    /// `staging → stage` for a guided rename, otherwise the scope label.
    static func scopeTitle(_ scope: ScopeChangeSummaryModel) -> String {
        if case .renamed(let from) = scope.environmentChange {
            return String(
                localized: "sync.summary.scope.renamed.title",
                defaultValue: "\(from) → \(scopeLabel(scope.label))"
            )
        }
        return scopeLabel(scope.label)
    }

    /// "2 added, 1 modified, 1 deleted in production" (§7.2), or the environment-level change.
    static func scopeSentence(_ scope: ScopeChangeSummaryModel) -> String {
        let label = scopeLabel(scope.label)
        switch scope.environmentChange {
        case .renamed(let from):
            return String(
                localized: "sync.summary.scope.renamed",
                defaultValue: "\(from) renamed to \(label) (recreated on GitHub)"
            )
        case .deleted:
            return String(
                localized: "sync.summary.scope.deleted",
                defaultValue: "\(label) deleted — contents fetched live at confirmation"
            )
        case .created, .policyChanged, nil:
            break
        }
        var parts: [String] = []
        if scope.addedCount > 0 {
            parts.append(String(localized: "sync.summary.count.added", defaultValue: "\(scope.addedCount) added"))
        }
        if scope.renamedCount > 0 {
            parts.append(String(localized: "sync.summary.count.renamed", defaultValue: "\(scope.renamedCount) renamed"))
        }
        if scope.modifiedCount > 0 {
            parts.append(String(localized: "sync.summary.count.modified", defaultValue: "\(scope.modifiedCount) modified"))
        }
        if scope.deletedCount > 0 {
            parts.append(String(localized: "sync.summary.count.deleted", defaultValue: "\(scope.deletedCount) deleted"))
        }
        let counts = parts.joined(separator: String(localized: "sync.list.separator", defaultValue: ", "))
        switch scope.environmentChange {
        case .created where counts.isEmpty:
            return String(localized: "sync.summary.scope.created", defaultValue: "\(label) created")
        case .created:
            return String(localized: "sync.summary.scope.createdWithItems", defaultValue: "\(label) created with \(counts)")
        case .policyChanged where counts.isEmpty:
            return String(localized: "sync.summary.scope.policy", defaultValue: "Deployment branches of \(label) changed")
        default:
            if counts.isEmpty {
                return String(localized: "sync.summary.scope.branchRules", defaultValue: "Branch rules of \(label) changed")
            }
            return String(localized: "sync.summary.scope.counts", defaultValue: "\(counts) in \(label)")
        }
    }

    /// `+ SENTRY_DSN (secret)`, `~ STRIPE_KEY (secret)`, `− OLD_NAME (variable)`,
    /// `OLD → NEW (variable)`.
    static func itemLine(_ item: ItemChangeSummaryModel) -> String {
        let kind = kindTitle(item.kind)
        switch item.change {
        case .added:
            return String(localized: "sync.summary.item.added", defaultValue: "+ \(item.name) (\(kind))")
        case .modified:
            return String(localized: "sync.summary.item.modified", defaultValue: "~ \(item.name) (\(kind))")
        case .deleted:
            return String(localized: "sync.summary.item.deleted", defaultValue: "− \(item.name) (\(kind))")
        case .renamed(let from):
            return String(localized: "sync.summary.item.renamed", defaultValue: "\(from) → \(item.name) (\(kind))")
        }
    }

    /// `policy: custom (release/*)`.
    static func policyLine(_ policy: PolicySummaryModel) -> String {
        switch policy.kind {
        case .all:
            return String(localized: "sync.summary.policy.all", defaultValue: "Deployment branches: all")
        case .protected:
            return String(localized: "sync.summary.policy.protected", defaultValue: "Deployment branches: protected only")
        case .custom:
            let patterns = policy.patterns.joined(separator: String(localized: "sync.list.separator", defaultValue: ", "))
            return String(localized: "sync.summary.policy.custom", defaultValue: "Deployment branches: selected (\(patterns))")
        }
    }

    /// `(new repository · private · README · Swift .gitignore · MIT)`.
    static func newRepositoryLine(_ model: NewRepositorySummaryModel) -> String {
        var parts = [model.visibility.localizedTitle]
        if model.addsReadme {
            parts.append(String(localized: "sync.summary.newRepo.readme", defaultValue: "README"))
        }
        if let gitignore = model.gitignoreTemplate {
            parts.append(String(localized: "sync.summary.newRepo.gitignore", defaultValue: "\(gitignore) .gitignore"))
        }
        if let license = model.licenseTemplate {
            parts.append(license)
        }
        let details = parts.joined(separator: " · ")
        return String(localized: "sync.summary.newRepo", defaultValue: "New repository · \(details)")
    }

    static func note(_ note: ChangeNoteModel) -> String {
        switch note {
        case .caseOnlyEnvironmentRename(_, let syncedName, let name):
            String(
                localized: "sync.summary.note.caseOnlyRename",
                defaultValue: "\(name) differs from \(syncedName) only in case: the change stays local and GitHub keeps \(syncedName)."
            )
        }
    }

    /// "FX Vault write limit this hour: 412 of 450" (§7.2, D12).
    static func writeBudgetLine(_ budget: WriteBudgetModel) -> String {
        String(
            localized: "sync.summary.writeBudget",
            defaultValue: "FX Vault write limit this hour: \(budget.used) of \(budget.limit)"
        )
    }

    static let writeBudgetHelp = String(
        localized: "sync.summary.writeBudget.help",
        defaultValue: "FX Vault's own limit. Other gh or GitHub activity also counts toward GitHub's limits."
    )

    static func writeBudgetExceeded(cost: Int) -> String {
        String(
            localized: "sync.summary.writeBudget.exceeded",
            defaultValue: "This sync needs about \(cost) writes, more than are left this hour. What does not fit stays pending for the next Sync."
        )
    }

    static let repositoryVariablesTooLarge = String(
        localized: "sync.summary.repoVariablesSize",
        defaultValue: "The repository variables add up to more than 256 KB. GitHub passes at most 256 KB of variables to a workflow run."
    )

    static let cloneFolderMissing = String(
        localized: "sync.summary.cloneFolderMissing",
        defaultValue: "No clone folder is set, so new repositories are not cloned during Sync. Clone them from the result, or choose a folder in Settings › General."
    )

    // MARK: - Changes

    /// The name the progress view shows for the change in flight.
    static func changeName(_ change: ConfigChangeModel) -> String {
        switch change.operation {
        case .createRepository(let create): "\(create.ownerLogin)/\(create.name)"
        case .upsertEnvironment(let upsert): upsert.name
        case .renameEnvironment(let rename): rename.toName
        case .reconcileBranchPatterns(let reconcile): reconcile.environmentName
        case .deleteEnvironment(let delete): delete.name
        case .setItem(let set): set.name
        case .deleteItem(let delete): delete.name
        }
    }

    /// One change as a result or blocked row: "Add secret API_TOKEN in production".
    static func changeTitle(_ change: ConfigChangeModel) -> String {
        switch change.operation {
        case .createRepository(let create):
            return String(
                localized: "sync.change.createRepository",
                defaultValue: "Create repository \(create.ownerLogin)/\(create.name)"
            )
        case .upsertEnvironment(let upsert):
            return upsert.isNew
                ? String(localized: "sync.change.createEnvironment", defaultValue: "Create environment \(upsert.name)")
                : String(localized: "sync.change.updateEnvironment", defaultValue: "Update deployment branches of \(upsert.name)")
        case .renameEnvironment(let rename):
            return String(
                localized: "sync.change.renameEnvironment",
                defaultValue: "Recreate environment \(rename.fromName) as \(rename.toName)"
            )
        case .reconcileBranchPatterns(let reconcile):
            return String(
                localized: "sync.change.branchRules",
                defaultValue: "Update branch rules of \(reconcile.environmentName)"
            )
        case .deleteEnvironment(let delete):
            return String(localized: "sync.change.deleteEnvironment", defaultValue: "Delete environment \(delete.name)")
        case .setItem(let set):
            let kind = kindTitle(set.kind)
            let scope = scopeLabel(environmentName: set.environmentName)
            switch set.reason {
            case .added:
                return set.isNew
                    ? String(localized: "sync.change.addItem", defaultValue: "Add \(kind) \(set.name) in \(scope)")
                    : String(localized: "sync.change.updateItem", defaultValue: "Update \(kind) \(set.name) in \(scope)")
            case .renamed(let from):
                return String(
                    localized: "sync.change.renameItem",
                    defaultValue: "Rename \(kind) \(from) to \(set.name) in \(scope)"
                )
            case .modified, .forcePushed:
                return String(localized: "sync.change.updateItem", defaultValue: "Update \(kind) \(set.name) in \(scope)")
            case .copiedForEnvironmentRename:
                return String(localized: "sync.change.copyItem", defaultValue: "Copy \(kind) \(set.name) to \(scope)")
            }
        case .deleteItem(let delete):
            let kind = kindTitle(delete.kind)
            let scope = scopeLabel(environmentName: delete.environmentName)
            return String(localized: "sync.change.deleteItem", defaultValue: "Delete \(kind) \(delete.name) in \(scope)")
        }
    }

    // MARK: - Reasons (§7.4)

    static func blockReason(_ reason: SyncBlockReason) -> String {
        switch reason {
        case .change(.valueMissing):
            String(localized: "sync.blocked.valueMissing", defaultValue: "Value missing locally.")
        case .change(.renameNeedsValues(let names)):
            String(
                localized: "sync.blocked.renameNeedsValues",
                defaultValue: "The environment is recreated on GitHub, which needs every value. Fill these first: \(names.joined(separator: ", "))."
            )
        case .change(.remoteChanged):
            String(
                localized: "sync.blocked.remoteChanged",
                defaultValue: "Changed on GitHub since your last check. Review it before syncing."
            )
        case .change(.dependsOn), .dependsOn:
            String(localized: "sync.blocked.dependsOn", defaultValue: "Waits for another change that cannot run.")
        case .readOnly(.adminRequired), .readOnly(.unavailable):
            String(localized: "sync.blocked.adminRequired", defaultValue: "Needs admin rights on the repository.")
        case .readOnly(.archived):
            String(localized: "sync.blocked.archived", defaultValue: "The repository is archived on GitHub.")
        case .missingScopes(let scopes):
            String(
                localized: "sync.blocked.missingScopes",
                defaultValue: "The account's token lacks \(scopes.joined(separator: ", "))."
            )
        case .invalidName(let error), .invalidValue(let error), .scopeFull(let error):
            error.localizedMessage
        case .listingFailed(let error):
            error.localizedMessage
        case .protectionRulesPresent:
            String(
                localized: "sync.blocked.protectionRules",
                defaultValue: "This environment has other protection rules on GitHub (reviewers, wait timers or app rules). Change its branch policy on GitHub so they are kept."
            )
        case .space(let block):
            spaceBlock(block.decision)
        case .sharedEnvironment:
            String(
                localized: "sync.blocked.sharedEnvironment",
                defaultValue: "This environment is shared with teammates. Renaming or deleting a shared environment is not supported yet."
            )
        }
    }

    // MARK: - Shared spaces (v0.6.0)

    /// Why a shared scope cannot be pushed now (S5).
    static func spaceBlock(_ decision: SpaceGateDecision) -> String {
        switch decision {
        case .behind(let version, let login):
            String(
                localized: "sync.space.behind",
                defaultValue: "\(login) published v\(version), which this Mac does not have yet. Get it from your teammates first, so nothing they changed is overwritten."
            )
        case .publishing(let login, let since, false):
            String(
                localized: "sync.space.publishing",
                defaultValue: "\(login) has been pushing to this scope since \(since.formatted(date: .omitted, time: .shortened)). Sync again when they are done."
            )
        case .publishing(let login, let since, true):
            String(
                localized: "sync.space.publishingStale",
                defaultValue: "\(login) started pushing to this scope at \(since.formatted(date: .abbreviated, time: .shortened)) and never finished. You can take over."
            )
        case .forked:
            String(
                localized: "sync.space.forked",
                defaultValue: "Two teammates pushed to this scope at the same time. Get updates from your teammates and check its history before pushing."
            )
        case .invalidMarker:
            String(
                localized: "sync.space.invalidMarker",
                defaultValue: "The version marker on GitHub was not written by a member of this shared scope. Check its history before pushing."
            )
        case .notAMember:
            String(
                localized: "sync.space.notAMember",
                defaultValue: "This Mac was removed from the shared scope. Ask a member to add you again."
            )
        case .clear, .ahead:
            String(localized: "sync.space.clear", defaultValue: "Shared with teammates.")
        }
    }

    /// The title of a shared scope's issue: "Shared with teammates · production".
    static func spaceTitle(scope: String) -> String {
        String(localized: "sync.space.title", defaultValue: "Shared with teammates · \(scope)")
    }

    static func spaceBlockedCount(_ count: Int) -> String {
        String(localized: "sync.space.blockedCount", defaultValue: "\(count) changes wait for it.")
    }

    /// The note of a repository whose push publishes shared versions.
    static let spacePublishNote = String(
        localized: "sync.space.publishNote",
        defaultValue: "Some scopes are shared with teammates: this push becomes a new version they get automatically."
    )

    static let spaceReasonTitle = String(localized: "sync.space.reason.title", defaultValue: "What changed?")
    static let spaceReasonPlaceholder = String(
        localized: "sync.space.reason.placeholder",
        defaultValue: "Optional. Your teammates see it in the history."
    )

    static func takeOverTitle(_ login: String) -> String {
        String(localized: "sync.space.takeOver.title", defaultValue: "Take over \(login)'s unfinished push?")
    }

    static let takeOverMessage = String(
        localized: "sync.space.takeOver.message",
        defaultValue: "Do this only if they are not pushing anymore. Your push becomes the next version, and the takeover is recorded in its history."
    )

    static let takeOverConfirm = String(localized: "sync.space.takeOver.confirm", defaultValue: "Take Over")

    static let gettingUpdates = String(
        localized: "sync.space.gettingUpdates",
        defaultValue: "Getting updates from your teammates…"
    )

    static func failureReason(_ reason: SyncFailureReason) -> String {
        switch reason {
        case .github(let error):
            error.localizedMessage
        case .indeterminate:
            String(
                localized: "sync.failed.indeterminate",
                defaultValue: "GitHub did not confirm it in time. FX Vault checks it again before the next Sync."
            )
        case .valueMissing:
            String(localized: "sync.failed.valueMissing", defaultValue: "The value is missing locally.")
        case .invalidValue(let error):
            error.localizedMessage
        case .renameTargetIsSource:
            String(
                localized: "sync.failed.renameTargetIsSource",
                defaultValue: "GitHub returned the old environment for the new name. Nothing was deleted."
            )
        case .renameNotVerified:
            String(
                localized: "sync.failed.renameNotVerified",
                defaultValue: "The copies in the new environment were not confirmed, so the old environment is kept."
            )
        case .createConflict:
            String(
                localized: "sync.failed.createConflict",
                defaultValue: "A repository with this name exists on GitHub with another owner or visibility. Check it on GitHub."
            )
        case .locked:
            String(localized: "sync.failed.locked", defaultValue: "The vault locked during the sync.")
        }
    }

    static func skipReason(_ reason: SyncSkipReason) -> String {
        switch reason {
        case .dependencyFailed:
            String(localized: "sync.skipped.dependencyFailed", defaultValue: "A change it depends on failed.")
        case .pairNotVerified:
            String(
                localized: "sync.skipped.pairNotVerified",
                defaultValue: "The new name was not confirmed, so the old name is kept on GitHub."
            )
        case .runStopped(let stop):
            stopReason(stop)
        case .deletionNotConfirmed:
            String(localized: "sync.skipped.deletionNotConfirmed", defaultValue: "Deletion not confirmed.")
        }
    }

    static func stopReason(_ reason: SyncStopReason) -> String {
        switch reason {
        case .rateLimited:
            String(
                localized: "sync.stopped.rateLimited",
                defaultValue: "GitHub's rate limit stopped the sync. Sync again later; the rest stays pending."
            )
        case .writeBudgetExhausted:
            String(
                localized: "sync.stopped.writeBudget",
                defaultValue: "FX Vault's hourly write limit is used up. Sync again later; the rest stays pending."
            )
        case .tokenRevoked:
            String(
                localized: "sync.stopped.tokenRevoked",
                defaultValue: "GitHub rejected the account's token. Log in again in Terminal, then sync again."
            )
        case .notAuthenticated:
            String(
                localized: "sync.stopped.notAuthenticated",
                defaultValue: "The account is not logged in to the GitHub CLI. Log in in Terminal, then sync again."
            )
        case .cancelled:
            String(localized: "sync.stopped.cancelled", defaultValue: "The sync was cancelled. The rest stays pending.")
        case .locked:
            String(localized: "sync.stopped.locked", defaultValue: "The vault locked. The rest stays pending.")
        case .persistenceFailed:
            String(
                localized: "sync.stopped.persistence",
                defaultValue: "The vault could not record the sync, so it stopped. The rest stays pending."
            )
        }
    }

    static func verification(_ state: SyncVerificationState) -> String {
        switch state {
        case .verified:
            String(localized: "sync.succeeded.verified", defaultValue: "Confirmed on GitHub.")
        case .pending:
            String(
                localized: "sync.succeeded.pending",
                defaultValue: "Written. GitHub has not confirmed it yet; FX Vault checks again later."
            )
        case .notApplicable:
            String(localized: "sync.succeeded.done", defaultValue: "Done.")
        }
    }

    static func warning(_ warning: SyncWarningModel) -> String? {
        switch warning {
        case .valueNormalized(_, let name):
            String(
                localized: "sync.warning.valueNormalized",
                defaultValue: "Trailing line breaks were removed from \(name) before it was pushed."
            )
        case .foreignRulesChanged(_, let name):
            String(
                localized: "sync.warning.foreignRules",
                defaultValue: "Other protection rules of \(name) (reviewers, wait timers or app rules) changed on GitHub."
            )
        case .repositoryNotConfirmed(_, let name):
            String(
                localized: "sync.warning.repositoryNotConfirmed",
                defaultValue: "GitHub has not confirmed \(name) yet. The next Sync picks it up."
            )
        case .cloneRequested:
            nil
        case .spaceNotPublished:
            String(
                localized: "sync.warning.spaceNotPublished",
                defaultValue: "GitHub did not confirm the shared version marker. FX Vault finishes it at the next Sync or unlock; until then teammates may see the scope as being pushed."
            )
        case .spaceForked:
            String(
                localized: "sync.warning.spaceForked",
                defaultValue: "A teammate pushed to a shared scope at the same moment. Get updates from your teammates and check its history."
            )
        }
    }

    static func credentialReason(_ reason: CredentialReason) -> String {
        switch reason {
        case .keyContains(let pattern):
            String(localized: "sync.credential.keyContains", defaultValue: "the name contains \(pattern)")
        case .urlWithCredentials:
            String(localized: "sync.credential.url", defaultValue: "the value has a URL with a password")
        case .pemBlock:
            String(localized: "sync.credential.pem", defaultValue: "the value has a private key block")
        case .jsonWebToken:
            String(localized: "sync.credential.jwt", defaultValue: "the value looks like a JSON Web Token")
        case .knownTokenPrefix(let prefix):
            String(localized: "sync.credential.tokenPrefix", defaultValue: "the value starts like a \(prefix) token")
        case .highEntropy:
            String(localized: "sync.credential.entropy", defaultValue: "the value looks like a random key")
        }
    }

    // MARK: - Fix actions

    static func fixTitle(_ fix: SyncFixActionModel) -> String {
        switch fix {
        case .fillValue:
            String(localized: "sync.fix.fillValue", defaultValue: "Fill Value…")
        case .editItem:
            String(localized: "sync.fix.edit", defaultValue: "Edit…")
        case .convertToSecret:
            String(localized: "sync.fix.convertToSecret", defaultValue: "Convert to Secret…")
        case .reviewDrift:
            String(localized: "sync.fix.reviewDrift", defaultValue: "Review Drift…")
        case .askAdmin:
            String(localized: "sync.fix.askAdmin", defaultValue: "Ask an Admin")
        case .authorizeSAML:
            String(localized: "sync.fix.authorizeSAML", defaultValue: "Authorize…")
        case .runInTerminal:
            String(localized: "sync.fix.copyCommand", defaultValue: "Copy Terminal Command")
        case .learnMore:
            String(localized: "sync.fix.learnMore", defaultValue: "Learn More")
        case .clone:
            String(localized: "sync.fix.clone", defaultValue: "Clone")
        case .getTeammateUpdates:
            String(localized: "sync.fix.getTeammateUpdates", defaultValue: "Get Updates from Teammates")
        case .takeOverSpace:
            String(localized: "sync.fix.takeOver", defaultValue: "Take Over…")
        }
    }

    /// The request "Ask an Admin" copies (plain text, no values).
    static func adminRequest(login: String, fullName: String) -> String {
        String(
            localized: "sync.fix.askAdmin.request",
            defaultValue: "Could you give \(login) admin access to \(fullName) on GitHub? I need it to manage its environments, secrets and variables."
        )
    }

    static let adminRequestCopied = String(
        localized: "sync.notice.adminRequestCopied",
        defaultValue: "A request for admin access was copied. Send it to an admin of the repository."
    )

    static let commandCopied = String(
        localized: "sync.notice.commandCopied",
        defaultValue: "Command copied. Run it in Terminal, then sync again."
    )

    static let reportCopied = String(localized: "sync.notice.reportCopied", defaultValue: "Copied.")
}
