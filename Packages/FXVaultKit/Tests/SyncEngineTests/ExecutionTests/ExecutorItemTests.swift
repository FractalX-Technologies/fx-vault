import Foundation
import FXVaultTestSupport
import GitHubKit
@testable import SyncEngine
import Testing
import VaultCore

@Suite("SyncExecutor items")
struct ExecutorItemTests {
    // MARK: - Ordering, stdin, bookkeeping

    @Test func writesEnvironmentFirstThenScopesRepositoryFirstVariablesBeforeSecrets() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let staging = scenario.newEnvironment("staging")
        let repoSecret = scenario.newItem("FXV_TOKEN", kind: .secret, value: "secret-one")
        let repoVariable = scenario.newItem("FXV_URL", kind: .variable, value: "https://example.invalid")
        let envSecret = scenario.newItem("FXV_DSN", kind: .secret, value: "secret-two", in: staging)
        let envVariable = scenario.newItem("FXV_MODE", kind: .variable, value: "debug", in: staging)
        let world = ExecWorld(scenario, github: github)

        let result = try await world.sync()

        #expect(result.stopReason == nil)
        #expect(result.failed.isEmpty && result.blocked.isEmpty && result.skipped.isEmpty)
        #expect(result.succeeded.count == 5)
        let writes = github.writes.map { Array($0.prefix(3)) }
        #expect(writes == [
            ["api", "-H", "Accept: application/vnd.github+json"],
            ["variable", "set", "FXV_URL"],
            ["secret", "set", "FXV_TOKEN"],
            ["variable", "set", "FXV_MODE"],
            ["secret", "set", "FXV_DSN"],
        ])
        for id in [repoSecret, repoVariable, envSecret, envVariable] {
            let row = try #require(world.vault.item(id))
            #expect(row.isSynced && row.verifyState == .verified && !row.hasPendingChange)
        }
        #expect(github.variable("FXV_MODE", environment: "staging")?.value == "debug")
        #expect(world.vault.environment(staging.id)?.syncedName == "staging")
        #expect(world.vault.journal.filter(\.isWrite).allSatisfy { $0.state == .succeeded && $0.exitCode == 0 })
        #expect(ChangeSetBuilder.build(world.snapshot).isEmpty)
    }

    @Test func valuesTravelOnStdinOnlyAndNeverInArgv() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "stdin-only-secret")
        scenario.newItem("FXV_URL", kind: .variable, value: "stdin-only-variable")
        let world = ExecWorld(scenario, github: github)

        try await world.sync()

        let sets = github.invocations.filter { GHMatch.secretSet()($0.arguments) || GHMatch.variableSet()($0.arguments) }
        #expect(sets.count == 2)
        #expect(sets.map { String(decoding: $0.stdin, as: UTF8.self) }.sorted() == ["stdin-only-secret", "stdin-only-variable"])
        for invocation in github.invocations {
            #expect(!invocation.arguments.contains { $0.contains("stdin-only") })
            #expect(!invocation.environment.values.contains { $0.contains("stdin-only") })
        }
        #expect(!world.vault.journal.contains { "\($0)".contains("stdin-only") })
    }

    @Test func variableUpdateCostsTwoWrites() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.syncedItem("FXV_URL", kind: .variable, value: "new", syncedValue: "old", github: github)
        let world = ExecWorld(scenario, github: github)

        let preflight = try await world.preflight()
        #expect(preflight.estimatedWriteCost == Limits.variableUpdateWriteCost)
        _ = try await world.executor().run(SyncPlanner.plan(preflight))
        #expect(await world.scheduler.writesInLastHour == Limits.variableUpdateWriteCost)
        #expect(github.variable("FXV_URL")?.value == "new")
    }

    // MARK: - Failures stay pending

    @Test func adminRequiredFailsThatItemOnlyAndItStaysPending() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let denied = scenario.newItem("FXV_TOKEN", kind: .secret, value: "one")
        let other = scenario.newItem("FXV_URL", kind: .variable, value: "two")
        let world = ExecWorld(scenario, github: github)
        github.enqueue(
            .failure(stderr: "failed to set secret \"FXV_TOKEN\": HTTP 403: Must have admin rights to Repository. (https://api.github.com/repos/owner-a/api/actions/secrets/FXV_TOKEN)"),
            matching: GHMatch.secretSet("FXV_TOKEN")
        )

        let result = try await world.sync()

        #expect(result.outcome(of: .setSecret, "FXV_TOKEN") == .failed(.github(.adminRequired)))
        #expect(result.outcome(of: .setVariable, "FXV_URL") == .succeeded(.verified))
        #expect(result.stopReason == nil)
        #expect(world.vault.item(denied)?.isSynced == false)
        #expect(world.vault.item(other)?.isSynced == true)
        let journal = try #require(world.journal(.secretSet).first)
        #expect(journal.state == .failed && journal.errorCode == "adminRequired")
        #expect(ChangeSetBuilder.build(world.snapshot).pendingCount == 1)
    }

    @Test func serverErrorIsRetriedAndSucceeds() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let id = scenario.newItem("FXV_URL", kind: .variable, value: "v")
        let clock = SteppingClock()
        let world = ExecWorld(scenario, github: github, clock: clock)
        github.enqueue(
            .failure(stderr: "failed to set variable \"FXV_URL\": HTTP 503: Service Unavailable (https://api.github.com/repos/owner-a/api/actions/variables)"),
            matching: GHMatch.variableSet()
        )

        let result = try await world.sync()

        #expect(result.outcome(of: .setVariable) == .succeeded(.verified))
        #expect(github.calls.filter(GHMatch.variableSet()).count == 2)
        #expect(clock.sleeps.contains(Timeouts.idempotentRetryBackoff))
        #expect(world.vault.item(id)?.verifyState == .verified)
    }

    @Test func rateLimitBacksOffTwiceThenStopsWithTheRestPending() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_A", kind: .secret, value: "a")
        scenario.newItem("FXV_B", kind: .secret, value: "b")
        let clock = ManualClock()
        let world = ExecWorld(scenario, github: github, clock: clock)
        let limited = FakeCommandRunner.Response.failure(
            stderr: "failed to set secret \"FXV_A\": HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (https://api.github.com/repos/owner-a/api/actions/secrets/FXV_A)"
        )
        for _ in 0...Limits.rateLimitRetries {
            github.enqueue(limited, matching: GHMatch.secretSet("FXV_A"))
        }
        let preflight = try await world.preflight()
        let executor = world.executor()
        let run = Task { try await executor.run(SyncPlanner.plan(preflight)) }
        for _ in 0..<Limits.rateLimitRetries {
            await clock.waitForSleepers(count: 1)
            clock.advance(by: Timeouts.rateLimitBackoff)
        }
        let result = try await run.value

        #expect(result.stopReason == .rateLimited)
        #expect(result.outcome(of: .setSecret, "FXV_A") == .failed(.github(.rateLimited)))
        #expect(result.outcome(of: .setSecret, "FXV_B") == .skipped(.runStopped(.rateLimited)))
        #expect(github.calls.filter(GHMatch.secretSet("FXV_A")).count == Limits.rateLimitRetries + 1)
        #expect(github.calls.filter(GHMatch.secretSet("FXV_B")).isEmpty)
        #expect(clock.uptime == Timeouts.rateLimitBackoff * Limits.rateLimitRetries)
        #expect(ChangeSetBuilder.build(world.snapshot).pendingCount == 2)
    }

    @Test func tokenRevokedRefreshesOnceAndRetriesWithTheNewToken() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "v")
        let world = ExecWorld(scenario, github: github)
        github.enqueue(
            .failure(stderr: "HTTP 401: Bad credentials (https://api.github.com/repos/owner-a/api)\nTry authenticating with:  gh auth login -h github.com"),
            matching: GHMatch.secretSet()
        )

        let result = try await world.sync()

        #expect(result.outcome(of: .setSecret) == .succeeded(.verified))
        let tokens = github.invocations.filter { GHMatch.secretSet()($0.arguments) }.map { $0.environment["GH_TOKEN"] }
        #expect(tokens == [ExecScenario.token, GitHubSimulator.refreshedToken])
        #expect(github.calls.filter(GHMatch.authToken).count == 1)
    }

    // MARK: - Indeterminate outcomes

    @Test func timeoutThatReachedGitHubIsReconciledByTheVerificationRelist() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let id = scenario.newItem("FXV_TOKEN", kind: .secret, value: "v")
        let world = ExecWorld(scenario, github: github)
        let timeout = FakeCommandRunner.Response(exitCode: 143, didTimeOut: true)
        github.enqueueAfterApplying(timeout, matching: GHMatch.secretSet())
        for _ in 0..<Limits.idempotentRetries {
            github.enqueue(timeout, matching: GHMatch.secretSet())
        }

        let result = try await world.sync()

        #expect(result.outcome(of: .setSecret) == .succeeded(.verified))
        let journal = try #require(world.journal(.secretSet).first)
        #expect(journal.state == .reconciled)
        let row = try #require(world.vault.item(id))
        #expect(row.isSynced && row.verifyState == .verified)
        #expect(row.remoteUpdatedAt == github.secret("FXV_TOKEN")?.updatedAt)
    }

    @Test func timeoutThatDidNotReachGitHubStaysIndeterminateAndPending() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let id = scenario.newItem("FXV_TOKEN", kind: .secret, value: "v")
        let world = ExecWorld(scenario, github: github)
        for _ in 0...Limits.idempotentRetries {
            github.enqueue(FakeCommandRunner.Response(exitCode: 143, didTimeOut: true), matching: GHMatch.secretSet())
        }

        let result = try await world.sync()

        #expect(result.outcome(of: .setSecret) == .failed(.indeterminate))
        #expect(world.journal(.secretSet).first?.state == .indeterminate)
        #expect(world.vault.item(id)?.isSynced == false)
    }

    // MARK: - D27 between preflight and write

    @Test func remoteChangeBetweenPreflightAndWriteIsBlockedByThePerScopeRelist() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let id = scenario.syncedItem("FXV_TOKEN", kind: .secret, value: "rotated-locally", syncedValue: "old", github: github)
        let world = ExecWorld(scenario, github: github)

        let preflight = try await world.preflight()
        #expect(preflight.repositories[0].executable.count == 1)
        github.addSecret("FXV_TOKEN")
        let result = try await world.executor().run(SyncPlanner.plan(preflight))

        #expect(result.outcome(of: .setSecret) == .blocked(.change(.remoteChanged)))
        #expect(github.calls.filter(GHMatch.secretSet()).isEmpty)
        #expect(world.vault.item(id)?.syncedFingerprint == InMemorySyncVault.fingerprint("old", rowID: id))
    }

    @Test func preflightBlocksASecretChangedOnGitHub() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.syncedItem("FXV_TOKEN", kind: .secret, value: "new", syncedValue: "old", github: github)
        github.addSecret("FXV_TOKEN")
        let world = ExecWorld(scenario, github: github)

        let preflight = try await world.preflight()

        let repository = preflight.repositories[0]
        #expect(repository.executable.isEmpty)
        #expect(repository.remoteChanged.map(\.change.kind) == [.setSecret])
        #expect(preflight.summary.repositories[0].remoteChanged.count == 1)
    }

    @Test func preflightBlocksAVariableChangedOnGitHubAndAnAddWhoseNameExists() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.syncedItem("FXV_URL", kind: .variable, value: "new", syncedValue: "old", github: github)
        scenario.newItem("FXV_NEW", kind: .secret, value: "v")
        github.addVariable("FXV_URL", value: "teammate")
        github.addSecret("FXV_NEW")
        let world = ExecWorld(scenario, github: github)

        let preflight = try await world.preflight()

        #expect(Set(preflight.repositories[0].remoteChanged.map(\.change.kind)) == [.setVariable, .setSecret])
        #expect(preflight.repositories[0].executable.isEmpty)
    }

    // MARK: - Verification

    @Test func secretWhoseUpdatedAtDoesNotChangeStaysPending() async throws {
        let github = GitHubSimulator()
        github.configure { $0.secretSetKeepsUpdatedAt = true }
        let scenario = ExecScenario()
        let id = scenario.syncedItem("FXV_TOKEN", kind: .secret, value: "same-again", syncedValue: "old", github: github)
        let clock = SteppingClock()
        let world = ExecWorld(scenario, github: github, clock: clock)

        let result = try await world.sync()

        #expect(result.outcome(of: .setSecret) == .succeeded(.pending))
        let row = try #require(world.vault.item(id))
        #expect(row.verifyState == .pending && row.preWriteUpdatedAt == github.secret("FXV_TOKEN")?.updatedAt)
        #expect(clock.sleeps.filter { $0 == Timeouts.verifyRetryInterval }.count >= 1)
        #expect(clock.uptime >= Timeouts.verifyRetryWindow)
        #expect(!row.hasPendingChange)
    }

    @Test func variableStoredDifferentlyStaysPendingThenDriftSeesIt() async throws {
        let github = GitHubSimulator()
        github.configure { $0.variableStoredValue = "mangled" }
        let scenario = ExecScenario()
        let id = scenario.newItem("FXV_URL", kind: .variable, value: "sent")
        let world = ExecWorld(scenario, github: github)

        let result = try await world.sync()

        #expect(result.outcome(of: .setVariable) == .succeeded(.pending))
        #expect(world.vault.item(id)?.verifyState == .pending)
    }

    @Test func importedVariableEndingInNewlineIsRenamedNormalizedAndVerified() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let id = scenario.syncedItem(
            "FXV_OLD",
            kind: .variable,
            value: "line\n",
            syncedValue: "line\n",
            github: github,
            localName: "FXV_NEW"
        )
        let world = ExecWorld(scenario, github: github)

        let result = try await world.sync()

        #expect(result.outcome(of: .setVariable, "FXV_NEW") == .succeeded(.verified))
        #expect(result.outcome(of: .deleteVariable, "FXV_OLD") == .succeeded(.notApplicable))
        let set = try #require(github.invocations.first { GHMatch.variableSet("FXV_NEW")($0.arguments) })
        #expect(String(decoding: set.stdin, as: UTF8.self) == "line")
        #expect(github.variableNames() == ["FXV_NEW"])
        let row = try #require(world.vault.item(id))
        #expect(row.syncedName == "FXV_NEW" && row.verifyState == .verified)
        #expect(row.syncedFingerprint == InMemorySyncVault.fingerprint("line", rowID: id))
        #expect(world.vault.storedValue(of: id) == "line")
        #expect(world.snapshot.items.count == 1)
        #expect(result.warnings.contains(.valueNormalized(itemID: id, name: "FXV_NEW")))
        #expect(ChangeSetBuilder.build(world.snapshot).isEmpty)
    }

    // MARK: - Deletes

    @Test func deleteNotFoundCountsAsDoneWhenTheRelistNoLongerShowsIt() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let id = scenario.syncedItem("FXV_GONE", kind: .secret, value: "v", syncedValue: "v", github: github, isDeleted: true)
        let world = ExecWorld(scenario, github: github)
        let preflight = try await world.preflight()
        github.removeSecret("FXV_GONE")

        let result = try await world.executor().run(SyncPlanner.plan(preflight))

        #expect(result.outcome(of: .deleteSecret) == .succeeded(.notApplicable))
        #expect(world.vault.item(id) == nil)
        #expect(world.journal(.secretDelete).first?.state == .succeeded)
    }

    @Test func deleteNotFoundWithAFailingRelistStaysPending() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let id = scenario.syncedItem("FXV_GONE", kind: .secret, value: "v", syncedValue: "v", github: github, isDeleted: true)
        let world = ExecWorld(scenario, github: github)
        let preflight = try await world.preflight()
        github.enqueue(
            .failure(stderr: "failed to delete secret FXV_GONE: HTTP 404: Not Found (https://api.github.com/repos/owner-a/api/actions/secrets/FXV_GONE)"),
            matching: GHMatch.secretDelete()
        )
        github.afterCall(matching: GHMatch.secretDelete()) {
            github.enqueue(
                .failure(stderr: "failed to get secrets: HTTP 502: Bad Gateway (https://api.github.com/repos/owner-a/api/actions/secrets)"),
                matching: GHMatch.secretList
            )
            for _ in 0..<Limits.idempotentRetries {
                github.enqueue(
                    .failure(stderr: "failed to get secrets: HTTP 502: Bad Gateway (https://api.github.com/repos/owner-a/api/actions/secrets)"),
                    matching: GHMatch.secretList
                )
            }
        }

        let result = try await world.executor().run(SyncPlanner.plan(preflight))

        #expect(result.outcome(of: .deleteSecret) == .failed(.github(.notFound)))
        #expect(world.vault.item(id)?.isDeleted == true)
        #expect(world.journal(.secretDelete).first?.errorCode == "notFound")
    }

    @Test func declinedItemDeletionLeavesARetryableTombstone() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.syncedItem("FXV_OLD", kind: .secret, value: "v", syncedValue: "v", github: github, localName: "FXV_NEW")
        let world = ExecWorld(scenario, github: github)

        let result = try await world.sync(includeDeletions: false)

        #expect(result.outcome(of: .setSecret, "FXV_NEW") == .succeeded(.verified))
        #expect(result.outcome(of: .deleteSecret, "FXV_OLD") == .skipped(.deletionNotConfirmed))
        #expect(github.secretNames() == ["FXV_NEW", "FXV_OLD"])
        let tombstone = try #require(world.snapshot.items.first { $0.isDeleted })
        #expect(tombstone.syncedName == "FXV_OLD")
        let next = ChangeSetBuilder.build(world.snapshot)
        #expect(next.changes.map(\.kind) == [.deleteSecret])

        let retry = try await world.sync()
        #expect(retry.outcome(of: .deleteSecret, "FXV_OLD") == .succeeded(.notApplicable))
        #expect(github.secretNames() == ["FXV_NEW"])
        #expect(world.snapshot.items.count == 1)
    }

    @Test func renameDeleteWaitsForTheVerifiedSet() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.syncedItem("FXV_OLD", kind: .secret, value: "v", syncedValue: "v", github: github, localName: "FXV_NEW")
        let world = ExecWorld(scenario, github: github)
        github.enqueue(.failure(stderr: "failed to set secret \"FXV_NEW\": HTTP 422: Invalid request."), matching: GHMatch.secretSet())

        let result = try await world.sync()

        guard case .failed(.github(.validation)) = result.outcome(of: .setSecret, "FXV_NEW") else {
            Issue.record("a 422 must fail the set as a validation error")
            return
        }
        guard case .skipped(.pairNotVerified) = result.outcome(of: .deleteSecret, "FXV_OLD") else {
            Issue.record("the old name must be kept")
            return
        }
        #expect(github.secretNames() == ["FXV_OLD"])
    }

    // MARK: - Cancellation and lock

    @Test func cancellationKeepsCompletedItemsSyncedAndSkipsTheRest() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let first = scenario.newItem("FXV_A", kind: .secret, value: "a")
        let second = scenario.newItem("FXV_B", kind: .secret, value: "b")
        let world = ExecWorld(scenario, github: github)
        let preflight = try await world.preflight()
        let executor = world.executor()
        github.afterCall(matching: GHMatch.secretSet("FXV_A")) { executor.cancel() }

        let result = try await executor.run(SyncPlanner.plan(preflight))

        #expect(result.stopReason == .cancelled)
        #expect(result.outcome(of: .setSecret, "FXV_A") == .succeeded(.pending))
        #expect(result.outcome(of: .setSecret, "FXV_B") == .skipped(.runStopped(.cancelled)))
        let completed = try #require(world.vault.item(first))
        #expect(completed.isSynced && completed.verifyState == .pending)
        #expect(world.vault.item(second)?.isSynced == false)
        #expect(github.calls.filter(GHMatch.secretSet("FXV_B")).isEmpty)
    }

    @Test func lockingMidRunStopsBeforeTheNextValueIsRead() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_A", kind: .secret, value: "a")
        scenario.newItem("FXV_B", kind: .secret, value: "b")
        let world = ExecWorld(scenario, github: github)
        let preflight = try await world.preflight()
        let vault = world.vault
        github.afterCall(matching: GHMatch.secretSet("FXV_A")) { vault.lock() }

        let result = try await world.executor().run(SyncPlanner.plan(preflight))

        #expect(result.stopReason == .locked)
        #expect(result.outcome(of: .setSecret, "FXV_A") == .succeeded(.pending))
        #expect(result.outcome(of: .setSecret, "FXV_B") == .skipped(.runStopped(.locked)))
        #expect(world.journal(.secretSet).map(\.state) == [.succeeded])
        #expect(github.calls.filter(GHMatch.secretSet("FXV_B")).isEmpty)
    }

    @Test func aFailedCommitStopsTheRunAndLeavesTheWriteInFlightForReconciliation() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let id = scenario.newItem("FXV_A", kind: .secret, value: "a")
        scenario.newItem("FXV_B", kind: .secret, value: "b")
        let world = ExecWorld(scenario, github: github)
        let preflight = try await world.preflight()
        world.vault.failCommits(after: 1)

        let result = try await world.executor().run(SyncPlanner.plan(preflight))

        #expect(result.stopReason == .persistenceFailed)
        #expect(world.journal(.secretSet).map(\.state) == [.inFlight])
        #expect(github.secret("FXV_A") != nil && github.secret("FXV_B") == nil)
        #expect(world.vault.item(id)?.isSynced == false)

        world.vault.failCommits(after: Int.max)
        let reconciled = try await world.reconciler().reconcile(world.vault.snapshots)
        #expect(reconciled.reconciled.count == 1)
        #expect(world.vault.item(id)?.verifyState == .verified)
    }

    @Test func progressReportsEveryChangeAndFinishes() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_A", kind: .secret, value: "a")
        scenario.newItem("FXV_B", kind: .variable, value: "b")
        let world = ExecWorld(scenario, github: github)
        let preflight = try await world.preflight()
        let executor = world.executor()
        let collector = Task {
            var events: [SyncProgressEventModel] = []
            for await event in executor.progress { events.append(event) }
            return events
        }

        _ = try await executor.run(SyncPlanner.plan(preflight))
        let events = await collector.value

        #expect(events.first == .started(total: 2))
        let finished = events.compactMap { event -> Int? in
            if case .changeFinished(_, let completed, _) = event { return completed }
            return nil
        }
        #expect(finished == [1, 2])
        guard case .finished = events.last else {
            Issue.record("the stream must end with .finished")
            return
        }
        await #expect(throws: SyncError.alreadyRunning) {
            try await executor.run(SyncPlanner.plan(preflight))
        }
    }
}
