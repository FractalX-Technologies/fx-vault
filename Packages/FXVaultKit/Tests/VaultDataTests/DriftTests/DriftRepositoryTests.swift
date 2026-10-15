import Foundation
import FXVaultTestSupport
import GitHubKit
import SyncEngine
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// ``DriftRepository`` end to end (§7.7): an imported repository, changes made on the
/// simulated GitHub, detection through full re-lists, and both resolutions of each finding.
@Suite("DriftRepository", .timeLimit(.minutes(1)))
struct DriftRepositoryTests {
    /// GitHub: repository secret `FXV_TOKEN`, repository variable `FXV_URL = one`, environment
    /// `staging` with variable `FXV_STAGE = s`. The vault imported it.
    private func imported() async throws -> SyncHarness {
        let github = GitHubSimulator(owner: SyncFixture.owner, name: SyncFixture.repoName)
        github.addSecret("FXV_TOKEN")
        github.addVariable("FXV_URL", value: "one")
        github.addEnvironment("staging", id: 21)
        github.addVariable("FXV_STAGE", value: "s", environment: "staging")
        let harness = try await SyncHarness.make(github: github)
        try await harness.importRepository()
        return harness
    }

    private func refresh(_ harness: SyncHarness) async throws -> DriftReportModel {
        try await harness.drift.refresh(harness.repository().id)
    }

    private func onlyDrift(_ harness: SyncHarness, kind: DriftKind) async throws -> DriftModel {
        let report = try await refresh(harness)
        #expect(report.drifts.map(\.kind) == [kind])
        return try #require(report.drifts.first { $0.kind == kind })
    }

    /// GitHub's state as another client would change it (through gh, not the simulator's
    /// helpers).
    private func otherClient(_ harness: SyncHarness) async throws -> (GHCommandScheduler, GHRepoRef) {
        (try await harness.schedulers.scheduler(for: SyncFixture.login), try GHRepoRef(owner: SyncFixture.owner, name: SyncFixture.repoName))
    }

    // MARK: - Clean state

    @Test func freshImportHasNoDrift() async throws {
        let harness = try await imported()
        let report = try await refresh(harness)
        #expect(report.drifts.isEmpty)
        #expect(report.unreadable.isEmpty)
        #expect(report.count == 0)
    }

    // MARK: - Variable modified

    @Test(arguments: DriftResolutionOption.allCases)
    func variableModified(option: DriftResolutionOption) async throws {
        let harness = try await imported()
        harness.github.addVariable("FXV_URL", value: "two")
        let drift = try await onlyDrift(harness, kind: .variableModified)
        let id = try #require(try harness.item("FXV_URL", kind: .variable)?.id)

        try await harness.drift.resolve(drift, option: option)

        switch option {
        case .keepLocal:
            #expect(try harness.value(id) == "one")
            #expect(try harness.syncedValue(id) == "two")
            #expect(try harness.pendingCount() == 1)
            _ = try await harness.runSync()
            #expect(harness.github.variable("FXV_URL")?.value == "one")
        case .acceptGitHub:
            #expect(try harness.value(id) == "two")
            #expect(try harness.syncedValue(id) == "two")
            #expect(try harness.pendingCount() == 0)
        }
        #expect(try await refresh(harness).drifts.isEmpty)
    }

    // MARK: - Secret modified (+ "Enter new value")

    @Test func secretModifiedAcceptGitHubThenEnterNewValue() async throws {
        let harness = try await imported()
        let later = GitHubSimulator.epoch.addingTimeInterval(3600)
        harness.github.addSecret("FXV_TOKEN", updatedAt: later)
        let drift = try await onlyDrift(harness, kind: .secretModified)
        #expect(drift.remoteUpdatedAt == later)
        // The imported secret has no local value: "Keep local" would need one.
        #expect(drift.keepLocal.unavailableReason == .valueMissing)
        await #expect(throws: DriftRepositoryError.resolutionUnavailable(.valueMissing)) {
            try await harness.drift.resolve(drift, option: .keepLocal)
        }

        let result = try await harness.drift.resolve(drift, option: .acceptGitHub)
        let id = try #require(try harness.item("FXV_TOKEN", kind: .secret)?.id)
        #expect(result.followUp == .promptFillValue(id))
        #expect(try harness.record(id).remoteUpdatedAt == DatabaseTimestamp.roundTripped(later))
        #expect(try harness.value(id) == nil)

        let entered = try await harness.drift.enterNewValue(id, value: SecretBytes(utf8: "rotated-value\n"))
        #expect(entered.didStripTrailingNewlines)
        #expect(try harness.value(id) == "rotated-value")
        #expect(try harness.pendingCount() == 0)
        #expect(try await refresh(harness).drifts.isEmpty)
    }

    @Test func secretModifiedKeepLocalPushesTheLocalValueAgain() async throws {
        let harness = try await imported()
        let id = try #require(try harness.item("FXV_TOKEN", kind: .secret)?.id)
        try harness.config.fillValue(id, value: SecretBytes(utf8: "mine"), pushOnNextSync: false)
        harness.github.addSecret("FXV_TOKEN", updatedAt: GitHubSimulator.epoch.addingTimeInterval(7200))
        let drift = try await onlyDrift(harness, kind: .secretModified)

        try await harness.drift.resolve(drift, option: .keepLocal)

        #expect(try harness.record(id).forcePush)
        #expect(try harness.pendingCount() == 1)
        let outcome = try await harness.runSync()
        #expect(outcome.result.failed.isEmpty)
        #expect(outcome.result.blocked.isEmpty)
        #expect(harness.github.secret("FXV_TOKEN")?.value == "mine")
        #expect(try await refresh(harness).drifts.isEmpty)
    }

    // MARK: - Remote added

    @Test func remoteAddedAcceptGitHubImportsBothKinds() async throws {
        let harness = try await imported()
        harness.github.addVariable("FXV_NEW_VARIABLE", value: "n")
        harness.github.addSecret("FXV_NEW_SECRET")
        let report = try await refresh(harness)
        #expect(report.drifts.map(\.kind) == [.remoteAdded, .remoteAdded])
        for drift in report.drifts {
            try await harness.drift.resolve(drift, option: .acceptGitHub)
        }
        let variable = try #require(try harness.item("FXV_NEW_VARIABLE", kind: .variable))
        #expect(try harness.value(variable.id) == "n")
        #expect(variable.provenance == .github)
        let secret = try #require(try harness.item("FXV_NEW_SECRET", kind: .secret))
        #expect(!secret.hasValue)
        #expect(secret.syncedName == "FXV_NEW_SECRET")
        #expect(try harness.pendingCount() == 0)
        #expect(try await harness.drift.report(for: harness.repository().id)?.drifts.isEmpty == true)
        #expect(try await refresh(harness).drifts.isEmpty)
    }

    @Test func remoteAddedKeepLocalDeletesItOnGitHub() async throws {
        let harness = try await imported()
        harness.github.addVariable("FXV_STRAY", value: "x", environment: "staging")
        let drift = try await onlyDrift(harness, kind: .remoteAdded)
        try await harness.drift.resolve(drift, option: .keepLocal)
        let tombstone = try #require(try harness.states().first { $0.isDeleted })
        #expect(tombstone.name == "FXV_STRAY")
        #expect(try harness.pendingCount() == 1)
        _ = try await harness.runSync()
        #expect(harness.github.variable("FXV_STRAY", environment: "staging") == nil)
        #expect(try await refresh(harness).drifts.isEmpty)
    }

    // MARK: - Remote deleted

    @Test func remoteDeletedSecretAcceptGitHubRemovesTheRow() async throws {
        let harness = try await imported()
        harness.github.removeSecret("FXV_TOKEN")
        let drift = try await onlyDrift(harness, kind: .remoteDeleted)
        #expect(drift.keepLocal.unavailableReason == .valueMissing)
        try await harness.drift.resolve(drift, option: .acceptGitHub)
        #expect(try harness.item("FXV_TOKEN", kind: .secret) == nil)
        #expect(try harness.pendingCount() == 0)
    }

    @Test func remoteDeletedVariableKeepLocalRecreatesIt() async throws {
        let harness = try await imported()
        let (scheduler, ref) = try await otherClient(harness)
        try await scheduler.deleteVariable("FXV_URL", repo: ref)
        let drift = try await onlyDrift(harness, kind: .remoteDeleted)
        try await harness.drift.resolve(drift, option: .keepLocal)
        let row = try #require(try harness.item("FXV_URL", kind: .variable))
        #expect(row.syncedName == nil)
        #expect(try harness.pendingCount() == 1)
        _ = try await harness.runSync()
        #expect(harness.github.variable("FXV_URL")?.value == "one")
    }

    // MARK: - Environments

    @Test func environmentAddedAcceptGitHubImportsIt() async throws {
        let harness = try await imported()
        harness.github.addEnvironment("qa", id: 31, policy: .custom, patterns: [("v*", .tag)])
        harness.github.addVariable("FXV_QA", value: "q", environment: "qa")
        let drift = try await onlyDrift(harness, kind: .environmentAdded)
        guard case .environment(let subject) = drift.subject else {
            Issue.record("Expected an environment subject")
            return
        }
        #expect(subject.remoteItemNames == ["FXV_QA"])

        try await harness.drift.resolve(drift, option: .acceptGitHub)

        let qa = try #require(try harness.environment("qa"))
        #expect(qa.syncedName == "qa")
        #expect(qa.githubEnvID == 31)
        #expect(qa.syncedBranchPolicy == .custom)
        #expect(qa.branchPolicy.patterns.map(\.pattern) == ["v*"])
        #expect(qa.branchPolicy.patterns.allSatisfy { $0.githubPolicyID != nil })
        let variable = try #require(try harness.item("FXV_QA", kind: .variable, scope: .environment(qa.id)))
        #expect(try harness.value(variable.id) == "q")
        #expect(try harness.pendingCount() == 0)
        #expect(try await refresh(harness).drifts.isEmpty)
    }

    @Test func environmentAddedKeepLocalDeletesItOnGitHub() async throws {
        let harness = try await imported()
        harness.github.addEnvironment("qa", id: 31)
        let drift = try await onlyDrift(harness, kind: .environmentAdded)
        try await harness.drift.resolve(drift, option: .keepLocal)
        #expect(try harness.environment("qa")?.isDeleted == true)
        #expect(try harness.pendingCount() == 1)
        _ = try await harness.runSync()
        #expect(harness.github.environment("qa") == nil)
        #expect(try harness.environment("qa") == nil)
    }

    @Test(arguments: DriftResolutionOption.allCases)
    func environmentDeleted(option: DriftResolutionOption) async throws {
        let harness = try await imported()
        harness.github.removeEnvironment("staging")
        let drift = try await onlyDrift(harness, kind: .environmentDeleted)
        try await harness.drift.resolve(drift, option: option)
        switch option {
        case .acceptGitHub:
            #expect(try harness.environment("staging") == nil)
            #expect(try harness.pendingCount() == 0)
        case .keepLocal:
            let staging = try #require(try harness.environment("staging"))
            #expect(staging.syncedName == nil)
            #expect(try harness.item("FXV_STAGE", kind: .variable, scope: .environment(staging.id))?.syncedName == nil)
            #expect(try harness.pendingCount() == 2)
            _ = try await harness.runSync()
            #expect(harness.github.environment("staging") != nil)
            #expect(harness.github.variable("FXV_STAGE", environment: "staging")?.value == "s")
        }
        #expect(try await refresh(harness).drifts.isEmpty)
    }

    @Test(arguments: DriftResolutionOption.allCases)
    func environmentPolicyModified(option: DriftResolutionOption) async throws {
        let harness = try await imported()
        harness.github.addEnvironment("staging", id: 21, policy: .protected)
        let drift = try await onlyDrift(harness, kind: .environmentPolicyModified)
        try await harness.drift.resolve(drift, option: option)
        let staging = try #require(try harness.environment("staging"))
        #expect(staging.syncedBranchPolicy == .protected)
        switch option {
        case .acceptGitHub:
            #expect(staging.branchPolicy == .protectedBranches)
            #expect(try harness.pendingCount() == 0)
        case .keepLocal:
            #expect(staging.branchPolicy == .all)
            #expect(try harness.pendingCount() == 1)
        }
    }

    // MARK: - Conflicts (§7.7: changed remotely while pending locally)

    @Test(arguments: DriftResolutionOption.allCases)
    func aNewLocalVariableWhoseNameGitHubAlreadyHas(option: DriftResolutionOption) async throws {
        let harness = try await imported()
        let id = try harness.add("FXV_BOTH", kind: .variable, value: "mine")
        harness.github.addVariable("FXV_BOTH", value: "theirs")
        let drift = try await onlyDrift(harness, kind: .remoteAdded)
        #expect(drift.isConflict)
        try await harness.drift.resolve(drift, option: option)
        let row = try harness.record(id)
        #expect(row.syncedName == "FXV_BOTH")
        #expect(try harness.syncedValue(id) == "theirs")
        switch option {
        case .keepLocal:
            #expect(try harness.value(id) == "mine")
            #expect(try harness.pendingCount() == 1)
            _ = try await harness.runSync()
            #expect(harness.github.variable("FXV_BOTH")?.value == "mine")
        case .acceptGitHub:
            #expect(try harness.value(id) == "theirs")
            #expect(try harness.pendingCount() == 0)
        }
        #expect(try await refresh(harness).drifts.isEmpty)
    }

    @Test(arguments: DriftResolutionOption.allCases)
    func aNewLocalSecretWhoseNameGitHubAlreadyHas(option: DriftResolutionOption) async throws {
        let harness = try await imported()
        let id = try harness.add("FXV_BOTH_SECRET", kind: .secret, value: "mine")
        harness.github.addSecret("FXV_BOTH_SECRET")
        let drift = try await onlyDrift(harness, kind: .remoteAdded)
        let result = try await harness.drift.resolve(drift, option: option)
        let row = try harness.record(id)
        #expect(row.syncedName == "FXV_BOTH_SECRET")
        switch option {
        case .keepLocal:
            #expect(row.forcePush)
            #expect(try harness.value(id) == "mine")
            #expect(try harness.pendingCount() == 1)
        case .acceptGitHub:
            #expect(result.followUp == .promptFillValue(id))
            #expect(try harness.value(id) == nil)
            #expect(try harness.pendingCount() == 0)
        }
    }

    @Test func aRenamedRowWhoseNewNameGitHubAlreadyHasKeepsDeletingTheOldName() async throws {
        let harness = try await imported()
        let url = try #require(try harness.item("FXV_URL", kind: .variable))
        let renamed = try harness.config.renameItem(url.id, to: "FXV_URL_V2")
        harness.github.addVariable("FXV_URL_V2", value: "remote-v2")
        let drift = try await onlyDrift(harness, kind: .remoteAdded)
        #expect(drift.acceptGitHub.effects.first == .detachSyncedIdentity(itemID: renamed))

        try await harness.drift.resolve(drift, option: .acceptGitHub)

        let row = try harness.record(renamed)
        #expect(row.syncedName == "FXV_URL_V2")
        #expect(try harness.value(renamed) == "remote-v2")
        let tombstone = try #require(try harness.states().first { $0.isDeleted })
        #expect(tombstone.syncedName == "FXV_URL")
        #expect(try harness.value(tombstone.id) == "one")
        #expect(try harness.pendingCount() == 1)
        _ = try await harness.runSync()
        #expect(harness.github.variable("FXV_URL") == nil)
        #expect(try await refresh(harness).drifts.isEmpty)
    }

    @Test(arguments: DriftResolutionOption.allCases)
    func aNewLocalEnvironmentGitHubAlreadyHas(option: DriftResolutionOption) async throws {
        let harness = try await imported()
        let id = try harness.config.createEnvironment(in: harness.repository().id, name: "qa")
        harness.github.addEnvironment("qa", id: 31, policy: .protected)
        let drift = try await onlyDrift(harness, kind: .environmentAdded)
        #expect(drift.isConflict)
        try await harness.drift.resolve(drift, option: option)
        let environment = try #require(try harness.store.fetchEnvironment(id: id))
        #expect(environment.syncedName == "qa")
        #expect(environment.githubEnvID == 31)
        #expect(environment.syncedBranchPolicy == .protected)
        switch option {
        case .keepLocal:
            #expect(environment.branchPolicy == .all)
            #expect(try harness.pendingCount() == 1)
        case .acceptGitHub:
            #expect(environment.branchPolicy == .protectedBranches)
            #expect(try harness.pendingCount() == 0)
        }
    }

    @Test func customPolicyAcceptGitHubTakesGitHubsPatterns() async throws {
        let harness = try await imported()
        harness.github.addEnvironment("staging", id: 21, policy: .custom, patterns: [("release/*", .branch), ("v*", .tag)])
        let drift = try await onlyDrift(harness, kind: .environmentPolicyModified)
        try await harness.drift.resolve(drift, option: .acceptGitHub)
        let staging = try #require(try harness.environment("staging"))
        #expect(staging.branchPolicy.kind == .custom)
        #expect(Set(staging.branchPolicy.patterns.map(\.pattern)) == ["release/*", "v*"])
        #expect(staging.branchPolicy.patterns.allSatisfy { $0.githubPolicyID != nil })
        #expect(try harness.pendingCount() == 0)
        #expect(try await refresh(harness).drifts.isEmpty)
    }

    @Test func environmentResolutionsAreCheckedAgainstGitHubToo() async throws {
        let harness = try await imported()
        harness.github.removeEnvironment("staging")
        let drift = try await onlyDrift(harness, kind: .environmentDeleted)
        harness.github.addEnvironment("staging", id: 22)
        await #expect(throws: DriftRepositoryError.stale) {
            try await harness.drift.resolve(drift, option: .acceptGitHub)
        }
        #expect(try harness.environment("staging") != nil)
    }

    // MARK: - Freshness, debounce, suppression

    @Test func aResolutionIsRefusedWhenGitHubChangedAgain() async throws {
        let harness = try await imported()
        harness.github.addVariable("FXV_URL", value: "two")
        let drift = try await onlyDrift(harness, kind: .variableModified)
        harness.github.addVariable("FXV_URL", value: "three")
        await #expect(throws: DriftRepositoryError.stale) {
            try await harness.drift.resolve(drift, option: .acceptGitHub)
        }
        let id = try #require(try harness.item("FXV_URL", kind: .variable)?.id)
        #expect(try harness.value(id) == "one")
    }

    @Test func openingARepositoryIsDebounced() async throws {
        let harness = try await imported()
        let repositoryID = try harness.repository().id
        _ = try await harness.drift.detectOnOpen(repositoryID)
        let afterFirst = harness.github.calls.count
        harness.github.addVariable("FXV_URL", value: "two")
        let cached = try await harness.drift.detectOnOpen(repositoryID)
        #expect(cached.drifts.isEmpty)
        #expect(harness.github.calls.count == afterFirst)

        try await harness.clock.sleep(for: Timeouts.driftDebounce)
        let fresh = try await harness.drift.detectOnOpen(repositoryID)
        #expect(fresh.drifts.map(\.kind) == [.variableModified])
        #expect(harness.github.calls.count > afterFirst)
    }

    @Test func ourOwnRecentDeletionIsNotReportedAsAdded() async throws {
        let harness = try await imported()
        let token = try #require(try harness.item("FXV_TOKEN", kind: .secret))
        try harness.config.deleteItem(token.id)
        _ = try await harness.runSync()
        #expect(harness.github.secret("FXV_TOKEN") == nil)
        // GitHub still lists the name for a while (eventual consistency).
        harness.github.addSecret("FXV_TOKEN")
        #expect(try await refresh(harness).drifts.isEmpty)

        // The window includes its start; one second later the name is reported again.
        try await harness.clock.sleep(for: Timeouts.recentDeletionSuppression + .seconds(1))
        let later = try await refresh(harness)
        #expect(later.drifts.map(\.kind) == [.remoteAdded])
    }

    @Test func pendingVerificationRunsFirstAndExpiresAfterTheLastCheck() async throws {
        let harness = try await imported()
        let id = try #require(try harness.item("FXV_TOKEN", kind: .secret)?.id)
        try harness.config.fillValue(id, value: SecretBytes(utf8: "pushed"), pushOnNextSync: true)
        // GitHub keeps updatedAt on this set (Q6 unknown): the push cannot be verified.
        harness.github.configure { $0.secretSetKeepsUpdatedAt = true }
        _ = try await harness.runSync()
        #expect(try harness.record(id).verifyState == .pending)

        for check in 1 ..< Limits.pendingVerifyChecks {
            let report = try await refresh(harness)
            #expect(report.drifts.isEmpty, "check \(check): a pending row is skipped")
            #expect(report.expiredItems.isEmpty)
        }
        let last = try await refresh(harness)
        #expect(last.expiredItems == [id])
        let row = try harness.record(id)
        #expect(row.verifyState == .verified)
        #expect(row.forcePush)
        #expect(try harness.pendingCount() == 1)
    }

    @Test func pendingVerificationConfirmsALandedWrite() async throws {
        let harness = try await imported()
        let id = try #require(try harness.item("FXV_TOKEN", kind: .secret)?.id)
        try harness.config.fillValue(id, value: SecretBytes(utf8: "pushed"), pushOnNextSync: true)
        harness.github.configure { $0.secretSetKeepsUpdatedAt = true }
        _ = try await harness.runSync()
        // The write shows up later.
        harness.github.addSecret("FXV_TOKEN", updatedAt: GitHubSimulator.epoch.addingTimeInterval(9000))
        let report = try await refresh(harness)
        #expect(report.verifiedItems == [id])
        #expect(report.drifts.isEmpty)
        #expect(try harness.record(id).verifyState == .verified)
    }

    // MARK: - Unreadable scopes

    @Test func anUnreadableScopeIsNotReportedAsDeleted() async throws {
        let harness = try await imported()
        harness.github.enqueue(
            .failure(stderr: GHFixtures.adminRequired),
            matching: { $0.starts(with: ["secret", "list"]) && !$0.contains { $0.hasPrefix("--env=") } }
        )
        let report = try await refresh(harness)
        #expect(report.drifts.isEmpty)
        #expect(report.unreadable.map(\.target) == [.secrets(environment: nil)])
    }

    @Test func unreadableEnvironmentsAreNotReportedAsDeleted() async throws {
        let harness = try await imported()
        harness.github.enqueue(
            GitHubSimulatorResponses.apiFailure(403, "Must have admin rights to Repository."),
            matching: { $0.first == "api" && $0.contains { $0.hasSuffix("/environments?per_page=100") } }
        )
        let report = try await refresh(harness)
        #expect(report.drifts.isEmpty)
        #expect(report.unreadable.map(\.target) == [.environments])
    }

    @Test func aRepositoryNotOnGitHubHasNoDrift() async throws {
        let harness = try await SyncHarness.make(github: GitHubSimulator(exists: false))
        let creation = RepoCreationRepository(session: harness.session, schedulers: harness.schedulers, git: nil)
        let staged = try await creation.stage(RepoCreationDraftModel(
            accountLogin: SyncFixture.login,
            ownerLogin: SyncFixture.owner,
            ownerType: .user,
            name: SyncFixture.repoName,
            visibility: .private,
            spec: RepoCreateSpecModel(autoInit: false, cloneAfter: false)
        ))
        let report = try await harness.drift.refresh(staged.repositoryID)
        #expect(report.drifts.isEmpty)
        #expect(harness.github.calls.isEmpty)
    }

    @Test func detectionNeedsAnUnlockedVault() async throws {
        let harness = try await imported()
        harness.manager.lock()
        await #expect(throws: DriftRepositoryError.vault(.locked)) {
            _ = try await refresh(harness)
        }
    }
}

/// gh api failure output in the simulator's format (`gh: <reason> (HTTP <status>)`).
enum GitHubSimulatorResponses {
    static func apiFailure(_ status: Int, _ reason: String) -> FakeCommandRunner.Response {
        .failure(
            stderr: "gh: \(reason) (HTTP \(status))\n",
            stdout: "HTTP/2.0 \(status) Forbidden\r\nContent-Type: application/json\r\n\r\n{\"message\":\"\(reason)\"}"
        )
    }
}
