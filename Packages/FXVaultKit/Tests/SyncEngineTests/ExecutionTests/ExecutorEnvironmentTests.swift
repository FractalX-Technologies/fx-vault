import Foundation
import FXVaultTestSupport
import GitHubKit
@testable import SyncEngine
import Testing
import VaultCore

@Suite("SyncExecutor repositories and environments")
struct ExecutorEnvironmentTests {
    // MARK: - Repository creation (§7.3 step 1, §8 C1)

    private static let createSpec = RepoCreateSpecModel(autoInit: true, gitignoreTemplate: "Swift", licenseTemplate: "mit", cloneAfter: true)

    @Test func createsTheRepositoryFirstThenItsEnvironmentPatternsAndItems() async throws {
        let github = GitHubSimulator(exists: false)
        let scenario = ExecScenario(onGitHub: false, spec: Self.createSpec)
        let production = scenario.newEnvironment("production", policy: .custom([]))
        scenario.environments[0].branchPolicy = .custom([
            BranchPatternModel(environmentID: production.id, pattern: "release/*", type: .branch),
        ])
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "s", in: production)
        scenario.newItem("FXV_URL", kind: .variable, value: "v", in: production)
        let world = ExecWorld(scenario, github: github)

        let result = try await world.sync()

        #expect(result.failed.isEmpty && result.skipped.isEmpty && result.blocked.isEmpty, "\(result.entries.map(\.outcome))")
        #expect(github.writes.first == ["repo", "create", "owner-a/api", "--private", "--add-readme", "--gitignore=Swift", "--license=mit"])
        #expect(!github.calls.joined().contains("--clone"))
        let repository = world.snapshot.repository
        #expect(repository.githubID == "R_simulated" && repository.defaultBranch == "main")
        #expect(world.journal(.repoView).first?.errorCode == "notFound")
        #expect(result.warnings.contains(.cloneRequested(repositoryID: repository.id)))
        #expect(github.environment("production")?.policy == .custom)
        #expect(github.environment("production")?.patterns.map(\.name) == ["release/*"])
        #expect(world.vault.environment(production.id)?.branchPolicy.patterns.allSatisfy(\.isSynced) == true)
        #expect(github.secretNames(environment: "production") == ["FXV_TOKEN"])
        #expect(ChangeSetBuilder.build(world.snapshot).isEmpty)
    }

    @Test func laterCommandsUseTheNameGhPrinted() async throws {
        let github = GitHubSimulator(exists: false)
        let scenario = ExecScenario(onGitHub: false, spec: Self.createSpec)
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "s")
        let world = ExecWorld(scenario, github: github)
        github.enqueue(.success("https://github.com/owner-a/api-normalized\n"), matching: GHMatch.repoCreate)
        github.afterCall(matching: GHMatch.repoCreate) { github.setRepository(exists: true, name: "api-normalized") }

        let result = try await world.sync()

        #expect(result.outcome(of: .setSecret) == .succeeded(.verified))
        let set = try #require(github.calls.first(where: GHMatch.secretSet()))
        #expect(set.contains("--repo=owner-a/api-normalized"))
        #expect(world.snapshot.repository.name == "api-normalized")
    }

    @Test func viewFailingDuringFreshRepoKeepsTheStdoutNameAndTheNextSyncAdopts() async throws {
        let github = GitHubSimulator(exists: false)
        let scenario = ExecScenario(onGitHub: false, spec: Self.createSpec)
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "s")
        let clock = SteppingClock()
        let world = ExecWorld(scenario, github: github, clock: clock)
        let preflight = try await world.preflight()
        let notResolved = FakeCommandRunner.Response.failure(stderr: "GraphQL: Could not resolve to a Repository with the name 'owner-a/api'. (repository)")
        let attempts = Int(Timeouts.freshRepoRetryWindow / Timeouts.freshRepoRetryInterval) + 1
        for _ in 0..<attempts {
            github.enqueue(notResolved, matching: GHMatch.repoView)
        }

        let result = try await world.executor().run(SyncPlanner.plan(preflight))

        #expect(result.outcome(of: .createRepository) == .succeeded(.notApplicable))
        #expect(result.outcome(of: .setSecret) == .succeeded(.verified))
        #expect(result.warnings.contains(.repositoryNotConfirmed(repositoryID: world.repositoryID, name: "api")))
        #expect(clock.sleeps.allSatisfy { $0 == Timeouts.freshRepoRetryInterval || $0 == Timeouts.verifyRetryInterval })
        #expect(world.snapshot.repository.githubID == nil)
        #expect(world.journal(.repoCreate).first?.state == .succeeded)

        let next = try await world.preflight()
        #expect(world.snapshot.repository.githubID == "R_simulated")
        #expect(next.repositories[0].executable.isEmpty)
        #expect(github.calls.filter(GHMatch.repoCreate).count == 1)
    }

    @Test func aTimedOutCreateIsAdoptedNeverRecreatedEvenWithTheMacClockAhead() async throws {
        let github = GitHubSimulator(exists: false)
        let scenario = ExecScenario(onGitHub: false, spec: Self.createSpec)
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "s")
        let clock = SteppingClock()
        let world = ExecWorld(scenario, github: github, clock: clock)
        let preflight = try await world.preflight()
        clock.setWallClock(to: SteppingClock.start.addingTimeInterval(TimeInterval(Timeouts.secondsPerDay / 2)))
        github.enqueueAfterApplying(FakeCommandRunner.Response(exitCode: 143, didTimeOut: true), matching: GHMatch.repoCreate)

        let result = try await world.executor().run(SyncPlanner.plan(preflight))

        #expect(result.outcome(of: .createRepository) == .succeeded(.notApplicable))
        #expect(result.outcome(of: .setSecret) == .succeeded(.verified))
        #expect(github.calls.filter(GHMatch.repoCreate).count == 1)
        #expect(world.journal(.repoCreate).first?.state == .reconciled)
        #expect(world.snapshot.repository.githubID == "R_simulated")
    }

    @Test func aTimedOutCreateWithAnotherVisibilityIsAConflict() async throws {
        let github = GitHubSimulator(exists: false)
        let scenario = ExecScenario(onGitHub: false, spec: Self.createSpec)
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "s")
        let world = ExecWorld(scenario, github: github)
        let preflight = try await world.preflight()
        github.enqueueAfterApplying(FakeCommandRunner.Response(exitCode: 143, didTimeOut: true), matching: GHMatch.repoCreate)
        github.afterCall(matching: GHMatch.repoCreate) { github.setRepository(exists: true, visibility: .public) }

        let result = try await world.executor().run(SyncPlanner.plan(preflight))

        #expect(result.outcome(of: .createRepository) == .failed(.createConflict))
        guard case .skipped(.dependencyFailed) = result.outcome(of: .setSecret) else {
            Issue.record("everything in the repository depends on its creation")
            return
        }
        #expect(github.calls.filter(GHMatch.repoCreate).count == 1)
        #expect(world.journal(.repoCreate).first?.errorCode == SyncExecutionConstants.createConflictErrorCode)
        #expect(world.snapshot.repository.githubID == nil)
    }

    @Test func anInvalidOwnerFailsTheCreateAndSkipsTheRepository() async throws {
        let github = GitHubSimulator(exists: false)
        let scenario = ExecScenario(onGitHub: false, spec: Self.createSpec)
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "s")
        let world = ExecWorld(scenario, github: github)
        github.enqueue(.failure(stderr: "HTTP 404: Not Found (https://api.github.com/users/owner-a)"), matching: GHMatch.repoCreate)

        let result = try await world.sync()

        guard case .failed(.github(.validation)) = result.outcome(of: .createRepository) else {
            Issue.record("a users/<owner> 404 is an invalid owner, \(String(describing: result.outcome(of: .createRepository)))")
            return
        }
        guard case .skipped(.dependencyFailed) = result.outcome(of: .setSecret) else {
            Issue.record("the secret must be skipped")
            return
        }
        #expect(github.calls.filter(GHMatch.repoView).count == 1)
    }

    @Test func notFoundInsideTheFreshRepoWindowIsRetriedNeverPlanGated() async throws {
        let github = GitHubSimulator(exists: false)
        let scenario = ExecScenario(onGitHub: false, spec: Self.createSpec)
        scenario.newEnvironment("production")
        let clock = SteppingClock()
        let world = ExecWorld(scenario, github: github, clock: clock)
        github.afterCall(matching: GHMatch.repoCreate) {
            for _ in 0..<3 {
                github.enqueue(
                    FakeCommandRunner.Response(exitCode: 1, stdout: Data("HTTP/2.0 404 Not Found\r\n\r\n".utf8), stderr: "gh: Not Found (HTTP 404)\n"),
                    matching: GHMatch.api("PUT", "environments/production")
                )
            }
        }

        let result = try await world.sync()

        #expect(result.outcome(of: .upsertEnvironment) == .succeeded(.notApplicable))
        #expect(clock.sleeps.filter { $0 == Timeouts.freshRepoRetryInterval }.count == 3)
        #expect(world.snapshot.repository.isEnvPlanGated == false)
    }

    // MARK: - Environments (§7.3 steps 2–3)

    @Test func aPlanGatedEnvironmentSkipsItsItemsAndSetsTheHint() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let staging = scenario.newEnvironment("staging")
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "s", in: staging)
        scenario.newItem("FXV_REPO", kind: .secret, value: "r")
        let world = ExecWorld(scenario, github: github)
        github.enqueue(
            FakeCommandRunner.Response(
                exitCode: 1,
                stdout: Data("HTTP/2.0 403 Forbidden\r\n\r\n".utf8),
                stderr: "gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)\n"
            ),
            matching: GHMatch.api("PUT", "environments/staging")
        )

        let result = try await world.sync()

        #expect(result.outcome(of: .upsertEnvironment) == .failed(.github(.planGated)))
        guard case .skipped(.dependencyFailed) = result.outcome(of: .setSecret, "FXV_TOKEN") else {
            Issue.record("items of a failed environment are skipped")
            return
        }
        #expect(result.outcome(of: .setSecret, "FXV_REPO") == .succeeded(.verified))
        #expect(world.snapshot.repository.isEnvPlanGated)
        #expect(world.vault.environment(staging.id)?.isSynced == false)
    }

    @Test func aPersistent404OnAnExistingRepositoryIsPlanGated() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newEnvironment("staging")
        let world = ExecWorld(scenario, github: github)
        github.enqueue(
            FakeCommandRunner.Response(exitCode: 1, stdout: Data("HTTP/2.0 404 Not Found\r\n\r\n".utf8), stderr: "gh: Not Found (HTTP 404)\n"),
            matching: GHMatch.api("PUT", "environments/staging")
        )

        let result = try await world.sync()

        #expect(result.outcome(of: .upsertEnvironment) == .failed(.github(.planGated)))
        #expect(world.journal(.environmentPut).first?.errorCode == "planGated")
    }

    @Test func patternsCountA200AndABare303AsSuccess() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let production = scenario.newEnvironment("production")
        scenario.environments[0].branchPolicy = .custom([
            BranchPatternModel(environmentID: production.id, pattern: "release/*", type: .branch),
            BranchPatternModel(environmentID: production.id, pattern: "v*", type: .tag),
        ])
        let world = ExecWorld(scenario, github: github)
        github.enqueueAfterApplying(
            FakeCommandRunner.Response(exitCode: 1, stdout: Data("HTTP/2.0 303 See Other\r\nContent-Length: 0\r\n\r\n".utf8), stderr: "gh: HTTP 303\n"),
            matching: GHMatch.api("POST", "deployment-branch-policies")
        )

        let result = try await world.sync()

        #expect(result.failed.isEmpty && result.blocked.isEmpty)
        let remote = try #require(github.environment("production"))
        #expect(Set(remote.patterns.map(\.name)) == ["release/*", "v*"])
        let local = try #require(world.vault.environment(production.id))
        #expect(Set(local.branchPolicy.patterns.compactMap(\.githubPolicyID)) == Set(remote.patterns.map(\.id)))
        #expect(world.journal(.branchPolicyAdd).allSatisfy { $0.state == .succeeded })
        #expect(ChangeSetBuilder.build(world.snapshot).isEmpty)
    }

    @Test func reconcileDeletesTombstonedAndExtraPatterns() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let production = scenario.syncedEnvironment("production", github: github, policy: .custom([
            BranchPatternModel(environmentID: EnvironmentID(), pattern: "release/*", type: .branch),
            BranchPatternModel(environmentID: EnvironmentID(), pattern: "hotfix/*", type: .branch),
        ]))
        guard case .custom(var patterns) = scenario.environments[0].branchPolicy else { return }
        patterns[1].isDeleted = true
        scenario.environments[0].branchPolicy = .custom(patterns)
        github.removeEnvironment("production")
        github.addEnvironment("production", id: 10, policy: .custom, patterns: [("release/*", .branch), ("hotfix/*", .branch), ("v*", .tag)])
        let ids = github.environment("production")?.patterns.map(\.id) ?? []
        do {
            scenario.environments[0].branchPolicy = .custom([
                BranchPatternModel(id: patterns[0].id, environmentID: production.id, pattern: "release/*", type: .branch, githubPolicyID: ids.first),
                BranchPatternModel(id: patterns[1].id, environmentID: production.id, pattern: "hotfix/*", type: .branch, githubPolicyID: ids.dropFirst().first, isDeleted: true),
            ])
        }
        let world = ExecWorld(scenario, github: github)

        let result = try await world.sync()

        #expect(result.outcome(of: .reconcileBranchPatterns) == .succeeded(.notApplicable))
        #expect(github.environment("production")?.patterns.map(\.name) == ["release/*"])
        #expect(world.journal(.branchPolicyDelete).count == 2)
        #expect(world.vault.environment(production.id)?.branchPolicy.patterns.map(\.pattern) == ["release/*"])
        #expect(ChangeSetBuilder.build(world.snapshot).isEmpty)
    }

    @Test func aFailedPatternPostFailsTheReconcile() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.syncedEnvironment("production", github: github, policy: .custom([]))
        let environmentID = scenario.environments[0].id
        scenario.environments[0].branchPolicy = .custom([
            BranchPatternModel(environmentID: environmentID, pattern: "release/*", type: .branch),
        ])
        let world = ExecWorld(scenario, github: github)
        github.enqueue(
            FakeCommandRunner.Response(exitCode: 1, stdout: Data("HTTP/2.0 422 Unprocessable Entity\r\n\r\n".utf8), stderr: "gh: Validation Failed (HTTP 422)\n"),
            matching: GHMatch.api("POST", "deployment-branch-policies")
        )

        let result = try await world.sync()

        guard case .failed(.github(.validation)) = result.outcome(of: .reconcileBranchPatterns) else {
            Issue.record("a rejected pattern fails the reconcile")
            return
        }
        #expect(world.journal(.branchPolicyAdd).first?.state == .failed)
        #expect(world.vault.environment(environmentID)?.branchPolicy.patterns.first?.isSynced == false)
    }

    @Test func anIndeterminateEnvironmentDeleteIsConfirmedByB3() async throws {
        let github = GitHubSimulator()
        let (scenario, qa) = tombstoneScenario(github)
        let world = ExecWorld(scenario, github: github)
        let timeout = FakeCommandRunner.Response(exitCode: 143, didTimeOut: true)
        github.enqueueAfterApplying(timeout, matching: GHMatch.api("DELETE", "environments/qa"))
        for _ in 0..<Limits.idempotentRetries {
            github.enqueue(timeout, matching: GHMatch.api("DELETE", "environments/qa"))
        }

        let result = try await world.sync()

        #expect(result.outcome(of: .deleteEnvironment) == .succeeded(.notApplicable))
        #expect(world.journal(.environmentDelete).first?.state == .reconciled)
        #expect(world.vault.environment(qa.id) == nil)
    }

    @Test func customToAllToCustomResetsAndRepostsThePatterns() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let production = scenario.syncedEnvironment("production", github: github, policy: .custom([
            BranchPatternModel(environmentID: EnvironmentID(), pattern: "release/*", type: .branch),
        ]))
        let patterns = scenario.environments[0].branchPolicy.patterns
        scenario.environments[0].branchPolicy = .all
        let world = ExecWorld(scenario, github: github)

        let toAll = try await world.sync()
        #expect(toAll.outcome(of: .upsertEnvironment) == .succeeded(.notApplicable))
        #expect(world.vault.commits.contains { $0.effects.contains(.patternsUnsynced(environmentID: production.id)) })
        #expect(github.environment("production")?.policy == .all)

        world.vault.updateSnapshot(world.repositoryID) { snapshot in
            snapshot.environments[0].branchPolicy = .custom(patterns.map { pattern in
                var pattern = pattern
                pattern.githubPolicyID = nil
                return pattern
            })
        }
        let toCustom = try await world.sync()
        #expect(toCustom.failed.isEmpty)
        #expect(github.environment("production")?.patterns.map(\.name) == ["release/*"])
        #expect(world.vault.environment(production.id)?.branchPolicy.patterns.allSatisfy(\.isSynced) == true)
    }

    @Test func changedForeignRulesProduceAWarning() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let production = scenario.syncedEnvironment("production", github: github)
        scenario.environments[0].branchPolicy = .protectedBranches
        github.removeEnvironment("production")
        github.addEnvironment("production", id: 10, foreignRules: [#"{"id":9001,"type":"required_reviewers"}"#])
        let world = ExecWorld(scenario, github: github)

        let result = try await world.sync()

        #expect(result.outcome(of: .upsertEnvironment) == .succeeded(.notApplicable))
        #expect(result.warnings.contains(.foreignRulesChanged(environmentID: production.id, name: "production")))
        #expect(world.vault.environment(production.id)?.foreignRulesJSON?.contains("required_reviewers") == true)
    }

    // MARK: - Guided rename (§7.6)

    private func renameScenario(_ github: GitHubSimulator) -> (ExecScenario, EnvironmentModel, ConfigItemID, ConfigItemID) {
        let scenario = ExecScenario()
        let staging = scenario.syncedEnvironment("staging", github: github, id: 10, policy: .custom([
            BranchPatternModel(environmentID: EnvironmentID(), pattern: "release/*", type: .branch),
        ]))
        let secret = scenario.syncedItem("FXV_TOKEN", kind: .secret, value: "s", syncedValue: "s", in: staging, github: github)
        let variable = scenario.syncedItem("FXV_URL", kind: .variable, value: "v", syncedValue: "v", in: staging, github: github)
        scenario.environments[0].name = "stage"
        return (scenario, staging, secret, variable)
    }

    @Test func renameCopiesVerifiesThenLeavesTheOldEnvironmentAsAPendingDeletion() async throws {
        let github = GitHubSimulator()
        let (scenario, staging, secret, variable) = renameScenario(github)
        let world = ExecWorld(scenario, github: github)

        let result = try await world.sync()

        #expect(result.failed.isEmpty && result.skipped.isEmpty && result.blocked.isEmpty, "\(result.entries.map(\.outcome))")
        #expect(result.outcome(of: .renameEnvironment) == .succeeded(.verified))
        #expect(!github.writes.contains { GHMatch.api("DELETE", "environments/staging")($0) })
        let newID = try #require(github.environment("stage")?.id)
        #expect(newID != 10)
        let moved = try #require(world.vault.environment(staging.id))
        #expect(moved.syncedName == "stage" && moved.githubEnvID == newID)
        #expect(moved.branchPolicy.patterns.first?.githubPolicyID == github.environment("stage")?.patterns.first?.id)
        let tombstone = try #require(world.snapshot.environments.first { $0.isDeleted })
        #expect(tombstone.syncedName == "staging" && tombstone.githubEnvID == 10 && tombstone.syncedBranchPolicy == .custom)
        for id in [secret, variable] {
            let row = try #require(world.vault.item(id))
            #expect(row.verifyState == .verified && !row.hasPendingChange)
        }
        #expect(world.vault.item(secret)?.remoteUpdatedAt == github.secret("FXV_TOKEN", environment: "stage")?.updatedAt)

        let next = ChangeSetBuilder.build(world.snapshot)
        #expect(next.changes.map(\.kind) == [.deleteEnvironment])
        let cleanup = try await world.sync()
        #expect(cleanup.outcome(of: .deleteEnvironment) == .succeeded(.notApplicable))
        #expect(github.environmentNames == ["stage"])
        #expect(ChangeSetBuilder.build(world.snapshot).isEmpty)
    }

    @Test func renameAbortsWithoutDeletingWhenTheNewEnvironmentHasTheOldID() async throws {
        let github = GitHubSimulator()
        github.configure { $0.environmentIDs[EnvironmentNameValidator.foldKey("stage")] = 10 }
        let (scenario, staging, _, _) = renameScenario(github)
        let world = ExecWorld(scenario, github: github)

        let result = try await world.sync()

        #expect(result.outcome(of: .renameEnvironment) == .failed(.renameTargetIsSource))
        guard case .skipped(.dependencyFailed) = result.outcome(of: .setSecret) else {
            Issue.record("copies are skipped")
            return
        }
        #expect(!github.writes.contains { $0.first == "secret" || $0.first == "variable" })
        #expect(world.vault.environment(staging.id)?.syncedName == "staging")
        #expect(world.snapshot.environments.allSatisfy { !$0.isDeleted })
        #expect(world.journal(.environmentPut).first?.errorCode == SyncExecutionConstants.renameTargetIsSourceErrorCode)
    }

    @Test func aFailedRenameVerificationKeepsTheOldEnvironment() async throws {
        let github = GitHubSimulator()
        github.configure { $0.variableStoredValue = "mangled" }
        let (scenario, staging, _, _) = renameScenario(github)
        let world = ExecWorld(scenario, github: github)

        let result = try await world.sync()

        #expect(result.outcome(of: .renameEnvironment) == .failed(.renameNotVerified))
        #expect(result.outcome(of: .setVariable) == .failed(.renameNotVerified))
        #expect(world.vault.environment(staging.id)?.syncedName == "staging")
        #expect(world.snapshot.environments.allSatisfy { !$0.isDeleted })
        #expect(github.environmentNames == ["stage", "staging"])
        #expect(ChangeSetBuilder.build(world.snapshot).changes.contains { $0.kind == .renameEnvironment })

        github.configure { $0.variableStoredValue = nil }
        let retry = try await world.sync()
        #expect(retry.outcome(of: .renameEnvironment) == .succeeded(.verified), "our own earlier PUT must not block the retry")
    }

    @Test func preflightBlocksARenameWhileASecretValueIsMissing() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let staging = scenario.syncedEnvironment("staging", github: github)
        scenario.syncedItem("FXV_TOKEN", kind: .secret, value: nil, syncedValue: "s", in: staging, github: github)
        scenario.environments[0].name = "stage"
        let world = ExecWorld(scenario, github: github)

        let preflight = try await world.preflight()

        let blocked = preflight.repositories[0].blocked
        #expect(blocked.contains { $0.change.kind == .renameEnvironment && $0.reason == .change(.renameNeedsValues(["FXV_TOKEN"])) })
        #expect(preflight.repositories[0].executable.isEmpty)
    }

    // MARK: - Environment deletes (§7.3 step 7)

    private func tombstoneScenario(_ github: GitHubSimulator) -> (ExecScenario, EnvironmentModel) {
        let scenario = ExecScenario()
        let qa = scenario.syncedEnvironment("qa", github: github, id: 20)
        scenario.environments[0].isDeleted = true
        return (scenario, qa)
    }

    @Test func anEnvironmentDeleteRemovesTheTombstone() async throws {
        let github = GitHubSimulator()
        let (scenario, qa) = tombstoneScenario(github)
        let world = ExecWorld(scenario, github: github)

        let result = try await world.sync()

        #expect(result.outcome(of: .deleteEnvironment) == .succeeded(.notApplicable))
        #expect(github.environmentNames.isEmpty)
        #expect(world.vault.environment(qa.id) == nil)
        #expect(world.journal(.environmentDelete).first?.state == .succeeded)
    }

    @Test func anEnvironmentDelete404IsDoneOnlyOnceB3NoLongerListsIt() async throws {
        let github = GitHubSimulator()
        let (scenario, qa) = tombstoneScenario(github)
        let world = ExecWorld(scenario, github: github)
        github.enqueue(
            FakeCommandRunner.Response(exitCode: 1, stdout: Data("HTTP/2.0 404 Not Found\r\n\r\n".utf8), stderr: "gh: HTTP 404\n"),
            matching: GHMatch.api("DELETE", "environments/qa")
        )
        github.afterCall(matching: GHMatch.api("DELETE", "environments/qa")) { github.removeEnvironment("qa") }

        let result = try await world.sync()

        #expect(result.outcome(of: .deleteEnvironment) == .succeeded(.notApplicable))
        #expect(world.vault.environment(qa.id) == nil)
    }

    @Test func anotherEnvironmentUnderTheTombstonesNameIsNotDeleted() async throws {
        let github = GitHubSimulator()
        let (scenario, qa) = tombstoneScenario(github)
        let world = ExecWorld(scenario, github: github)
        let preflight = try await world.preflight()
        github.removeEnvironment("qa")
        github.addEnvironment("qa", id: 21)

        let result = try await world.executor().run(SyncPlanner.plan(preflight))

        #expect(result.outcome(of: .deleteEnvironment) == .blocked(.change(.remoteChanged)))
        #expect(github.environmentNames == ["qa"])
        #expect(world.vault.environment(qa.id)?.isDeleted == true)
    }
}
