import Foundation
import FXVaultTestSupport
import GitHubKit
@testable import SyncEngine
import Testing
import VaultCore

@Suite("SyncPreflight")
struct PreflightTests {
    @Test func aWriteCollaboratorIsReadOnlyByDefaultAndRepoLevelOnlyWithThePolicy() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario(hasAdmin: false, hasPush: true)
        let staging = scenario.newEnvironment("staging")
        scenario.newItem("FXV_ENV", kind: .secret, value: "e", in: staging)
        scenario.newItem("FXV_REPO", kind: .secret, value: "r")
        let world = ExecWorld(scenario, github: github)

        let readOnly = try await world.preflight()
        #expect(readOnly.repositories[0].executable.isEmpty)
        #expect(readOnly.repositories[0].blocked.contains { $0.reason == .readOnly(.adminRequired) })

        let repoLevel = try await world.preflightService(writePolicy: .repoLevelOnly).run(world.vault.snapshots)
        #expect(repoLevel.repositories[0].executable.map(\.kind) == [.setSecret])
        let blockedKinds = repoLevel.repositories[0].blocked.filter { $0.reason == .readOnly(.adminRequired) }.map(\.change.kind)
        #expect(blockedKinds.sorted { $0.rawValue < $1.rawValue } == [.setSecret, .upsertEnvironment])
    }

    @Test func emptyAfterNormalizationAndMissingValuesAreBlocked() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_EMPTY", kind: .variable, value: "\r\n")
        scenario.newItem("FXV_MISSING", kind: .secret, value: nil)
        scenario.newItem("FXV_HUGE", kind: .secret, value: String(repeating: "x", count: Limits.maxValueBytes + 1))
        let world = ExecWorld(scenario, github: github)

        let preflight = try await world.preflight()

        let reasons = Dictionary(uniqueKeysWithValues: preflight.repositories[0].blocked.map { (ChangeTargetName.name(of: $0.change) ?? "", $0.reason) })
        #expect(reasons["FXV_EMPTY"] == .invalidValue(.emptyValue))
        #expect(reasons["FXV_MISSING"] == .change(.valueMissing))
        #expect(reasons["FXV_HUGE"] == .invalidValue(.valueTooLarge(limit: Limits.maxValueBytes)))
        #expect(preflight.repositories[0].executable.isEmpty)
    }

    @Test func missingTokenScopesBlockTheRepository() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "v")
        let world = ExecWorld(scenario, github: github)

        let preflight = try await world.preflight(scopeStatus: [ExecScenario.account: .missing(["read:org"])])

        #expect(preflight.repositories[0].blocked.map(\.reason) == [.missingScopes(["read:org"])])
    }

    @Test func aFullScopeBlocksTheAdd() async throws {
        let github = GitHubSimulator()
        for index in 0..<Limits.maxSecretsPerRepository {
            github.addSecret("FXV_S\(index)")
        }
        let scenario = ExecScenario()
        scenario.newItem("FXV_ONE_MORE", kind: .secret, value: "v")
        let world = ExecWorld(scenario, github: github)

        let preflight = try await world.preflight()

        #expect(preflight.repositories[0].blocked.map(\.reason) == [
            .scopeFull(.scopeFull(kind: .secret, limit: Limits.maxSecretsPerRepository)),
        ])
    }

    @Test func aListingFailureBlocksTheChangesThatNeedIt() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.syncedItem("FXV_TOKEN", kind: .secret, value: "new", syncedValue: "old", github: github)
        let world = ExecWorld(scenario, github: github)
        github.enqueue(
            .failure(stderr: "failed to get secrets: HTTP 403: Must have admin rights to Repository. (https://api.github.com/repos/owner-a/api/actions/secrets)"),
            matching: GHMatch.secretList
        )

        let preflight = try await world.preflight()

        #expect(preflight.repositories[0].blocked.map(\.reason) == [.listingFailed(.adminRequired)])
    }

    @Test func aLockedVaultFailsPreflight() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "v")
        let world = ExecWorld(scenario, github: github)
        world.vault.lock()

        await #expect(throws: SyncError.locked) {
            try await world.preflight()
        }
    }

    @Test func theWriteBudgetComesFromTheSeededScheduler() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "v")
        let clock = SteppingClock()
        let world = ExecWorld(scenario, github: github, clock: clock)
        let seeded = 5
        for minute in 1...seeded {
            world.vault.seedJournal(SyncJournalEntryModel(
                runID: SyncRunID(),
                accountLogin: ExecScenario.account,
                repositoryID: world.repositoryID,
                op: ConfigChangeKind.setSecret.rawValue,
                command: .secretSet,
                scopeLabel: SyncExecutionConstants.repositoryScopeLabel,
                targetKey: "item|secret|FXV_OLD|repo",
                state: .succeeded,
                startedAt: clock.now.addingTimeInterval(-TimeInterval(minute * Int(Timeouts.secondsPerMinute)))
            ))
        }
        world.vault.seedJournal(SyncJournalEntryModel(
            runID: SyncRunID(),
            accountLogin: ExecScenario.account,
            repositoryID: world.repositoryID,
            op: ConfigChangeKind.setSecret.rawValue,
            command: .secretSet,
            scopeLabel: SyncExecutionConstants.repositoryScopeLabel,
            targetKey: "item|secret|FXV_OLD|repo",
            state: .succeeded,
            startedAt: clock.now.addingTimeInterval(-TimeInterval(2 * Timeouts.secondsPerHour))
        ))

        try await SyncThrottleSeeder.seed(world.scheduler, from: world.vault, clock: clock)
        let preflight = try await world.preflight()

        #expect(preflight.writeBudgets[ExecScenario.account] == WriteBudgetModel(used: seeded))
        #expect(preflight.estimatedWriteCost == 1)
        #expect(!preflight.exceedsWriteBudget)
        #expect(preflight.summary.writeBudget == WriteBudgetModel(used: seeded))
    }

    @Test func aRunLargerThanTheRemainingBudgetIsFlagged() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "v")
        let world = ExecWorld(scenario, github: github)
        await world.scheduler.seed(recentWrites: Array(
            repeating: GHWriteRecordModel(date: world.clock.now, cost: Limits.defaultWriteCost),
            count: Limits.writesPerHour
        ))

        let preflight = try await world.preflight()

        #expect(preflight.exceedsWriteBudget)
        #expect(preflight.executableCount == 1 && preflight.deletionCount == 0)
    }

    @Test func largeRepositoryVariablesProduceTheSizeWarning() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let half = Limits.repoVariablesWarningBytes / 2
        scenario.newItem("FXV_A", kind: .variable, value: String(repeating: "a", count: half) + "\n")
        scenario.newItem("FXV_B", kind: .variable, value: String(repeating: "b", count: half))
        let world = ExecWorld(scenario, github: github)

        let atLimit = try await world.preflight()
        #expect(atLimit.repositories[0].repositoryVariableBytes == Limits.repoVariablesWarningBytes)
        #expect(!atLimit.repositories[0].exceedsRepositoryVariablesSize)

        world.vault.setValue(String(repeating: "b", count: half + 1), for: world.snapshot.items[1].id)
        let over = try await world.preflight()
        #expect(over.repositories[0].exceedsRepositoryVariablesSize)
    }

    @Test func errorsHaveValueFreeLogCodes() {
        let codes: [SyncError: String] = [
            .locked: "locked",
            .persistenceFailed: "persistenceFailed",
            .valueUnavailable(ConfigItemID()): "valueUnavailable",
            .accountUnavailable("user-a"): "accountUnavailable",
            .github(.rateLimited): "github(rateLimited)",
            .alreadyRunning: "alreadyRunning",
        ]
        for (error, code) in codes {
            #expect(error.logCode == code)
        }
        #expect(SyncStopReason.from(SyncError.github(.tokenRevoked)) == .tokenRevoked)
        #expect(SyncStopReason.from(SyncError.valueUnavailable(ConfigItemID())) == .locked)
        #expect(SyncStopReason.from(GHError.notFound) == nil)
    }

    @Test func thePendingVerificationPassResolvesOurOwnEarlierWrite() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let id = scenario.syncedItem("FXV_TOKEN", kind: .secret, value: "v", syncedValue: "v", github: github)
        scenario.items[0].verifyState = .pending
        scenario.items[0].preWriteUpdatedAt = scenario.items[0].remoteUpdatedAt
        scenario.items[0].forcePush = true
        let landed = github.addSecret("FXV_TOKEN")
        let world = ExecWorld(scenario, github: github)

        let preflight = try await world.preflight()

        let row = try #require(world.vault.item(id))
        #expect(row.verifyState == .verified && row.remoteUpdatedAt == landed)
        #expect(preflight.repositories[0].executable.map(\.kind) == [.setSecret])
        #expect(preflight.repositories[0].snapshot.items[0].verifyState == .verified)
    }

    @Test func aCreateWhoseNameIsTakenByAnotherRepositoryIsBlocked() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario(onGitHub: false)
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "v")
        let world = ExecWorld(scenario, github: github)

        let preflight = try await world.preflight()

        let repository = preflight.repositories[0]
        #expect(repository.executable.isEmpty)
        #expect(repository.blocked.first { $0.change.kind == .createRepository }?.reason == .change(.remoteChanged))
        #expect(repository.blocked.first { $0.change.kind == .setSecret }?.reason == .change(.dependsOn(changeID: "create_repository:repo")))
        #expect(world.journal(.repoView).first?.state == .succeeded)
    }

    @Test func anExistingTargetEnvironmentBlocksANewOneUnlessTheJournalShowsItIsOurs() async throws {
        let github = GitHubSimulator()
        github.addEnvironment("staging")
        let scenario = ExecScenario()
        scenario.newEnvironment("staging")
        let world = ExecWorld(scenario, github: github)

        let theirs = try await world.preflight()
        #expect(theirs.repositories[0].remoteChanged.map(\.change.kind) == [.upsertEnvironment])

        world.vault.seedJournal(SyncJournalEntryModel(
            runID: SyncRunID(),
            accountLogin: ExecScenario.account,
            repositoryID: world.repositoryID,
            op: ConfigChangeKind.upsertEnvironment.rawValue,
            command: .environmentPut,
            scopeLabel: "staging",
            targetKey: RemoteScopeKeyModel.environment(named: "staging").journalKey,
            state: .inFlight,
            startedAt: world.clock.now
        ))
        let ours = try await world.preflight()
        #expect(ours.repositories[0].executable.map(\.kind) == [.upsertEnvironment])
    }

    @Test func itemsOfAnEnvironmentDeletedOnGitHubAreRemoteChanged() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let staging = scenario.syncedEnvironment("staging", github: github)
        scenario.syncedItem("FXV_TOKEN", kind: .secret, value: "new", syncedValue: "old", in: staging, github: github)
        github.removeEnvironment("staging")
        let world = ExecWorld(scenario, github: github)

        let preflight = try await world.preflight()

        #expect(preflight.repositories[0].remoteChanged.map(\.change.kind) == [.setSecret])
    }

    @Test func aRenameIsBlockedWhenASourceItemChangedOnGitHub() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let staging = scenario.syncedEnvironment("staging", github: github)
        scenario.syncedItem("FXV_TOKEN", kind: .secret, value: "s", syncedValue: "s", in: staging, github: github)
        scenario.environments[0].name = "stage"
        github.addSecret("FXV_TOKEN", environment: "staging")
        let world = ExecWorld(scenario, github: github)

        let preflight = try await world.preflight()

        let repository = preflight.repositories[0]
        #expect(repository.remoteChanged.map(\.change.kind) == [.renameEnvironment])
        #expect(repository.executable.isEmpty)
    }

    @Test func noAccountSchedulerBlocksEverything() async throws {
        let scenario = ExecScenario()
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "v")
        let vault = InMemorySyncVault(snapshots: [scenario.snapshot], values: scenario.values.compactMapValues { $0 })
        let preflight = try await SyncPreflight(
            schedulers: SyncSchedulerRegistry([]),
            persistence: vault,
            values: vault,
            clock: SteppingClock()
        ).run(vault.snapshots)

        #expect(preflight.repositories[0].blocked.map(\.reason) == [.listingFailed(.notAuthenticated)])
        #expect(preflight.writeBudgets.isEmpty)
    }
}

@Suite("SyncPlanner")
struct PlannerTests {
    @Test func stepsFollowTheExecutionOrder() throws {
        let scenario = ExecScenario(onGitHub: false, spec: RepoCreateSpecModel(autoInit: false, cloneAfter: false))
        let github = GitHubSimulator()
        let staging = scenario.syncedEnvironment("staging", github: github, id: 10)
        scenario.syncedItem("FXV_OLD", kind: .secret, value: "v", syncedValue: "v", in: staging, github: github, isDeleted: true)
        let qa = scenario.syncedEnvironment("qa", github: github, id: 11)
        scenario.environments[1].isDeleted = true
        _ = qa
        let production = scenario.newEnvironment("production", policy: .custom([]))
        scenario.environments[2].branchPolicy = .custom([BranchPatternModel(environmentID: production.id, pattern: "release/*", type: .branch)])
        let renamed = scenario.syncedEnvironment("dev", github: github, id: 12)
        scenario.syncedItem("FXV_DEV", kind: .variable, value: "d", syncedValue: "d", in: renamed, github: github)
        scenario.environments[3].name = "development"
        scenario.newItem("FXV_SECRET", kind: .secret, value: "s")
        scenario.newItem("FXV_VARIABLE", kind: .variable, value: "v")
        scenario.newItem("FXV_PROD", kind: .secret, value: "p", in: production)
        let changeSet = ChangeSetBuilder.build(scenario.snapshot)
        let preflight = RepoPreflightModel(snapshot: scenario.snapshot, changeSet: changeSet, executable: changeSet.changes, blocked: [])

        let plan = SyncPlanner.plan(preflight)

        let shape = plan.steps.map { step -> String in
            switch step {
            case .createRepository: "create"
            case .upsertEnvironment(let environment): "upsert:\(environment.upsert.name)"
            case .reconcilePatterns(let patterns): "patterns:\(patterns.patterns.environmentName)"
            case .renameEnvironment(let rename): "rename:\(rename.rename.toName)+\(rename.copies.count)"
            case .writeScope(let scope): "write:\(scope.environmentName ?? "repo"):\(scope.changes.map(\.kind.rawValue).joined(separator: ","))"
            case .deleteItems(let scope): "delete:\(scope.environmentName ?? "repo")"
            case .deleteEnvironment(_, let delete): "deleteEnv:\(delete.name)"
            }
        }
        #expect(shape == [
            "create",
            "upsert:production",
            "patterns:production",
            "rename:development+1",
            "write:repo:set_variable,set_secret",
            "write:production:set_secret",
            "delete:staging",
            "deleteEnv:qa",
        ])
        #expect(plan.changes.count == changeSet.changes.count)
        #expect(plan.unconfirmedDeletions.isEmpty)
    }

    @Test func undeclaredDeletionsAreLeftOut() {
        let scenario = ExecScenario()
        let github = GitHubSimulator()
        scenario.syncedItem("FXV_OLD", kind: .secret, value: "v", syncedValue: "v", github: github, isDeleted: true)
        scenario.newItem("FXV_NEW", kind: .secret, value: "n")
        let changeSet = ChangeSetBuilder.build(scenario.snapshot)
        let preflight = RepoPreflightModel(snapshot: scenario.snapshot, changeSet: changeSet, executable: changeSet.changes, blocked: [])

        let plan = SyncPlanner.plan(preflight, includeDeletions: false)

        #expect(plan.changes.map(\.kind) == [.setSecret])
        #expect(plan.unconfirmedDeletions.map(\.kind) == [.deleteSecret])
        #expect(preflight.deletions.count == 1)
    }
}
