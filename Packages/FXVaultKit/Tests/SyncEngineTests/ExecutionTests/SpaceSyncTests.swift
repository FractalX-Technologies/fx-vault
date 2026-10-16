import Foundation
import FXVaultTestSupport
import GitHubKit
@testable import SyncEngine
import Testing
import VaultCore

/// Shared scopes in Sync (v0.6.0, tasks/todo.md S5): the gate in preflight, the claim before
/// the first write, the publish after, a lost claim, a takeover, and launch reconciliation.
@Suite("Shared space gate in Sync")
struct SpaceSyncTests {
    static let marker = GitHubNameValidator.spaceMarkerName
    let space = SpaceID()

    private func coordinator(_ world: ExecWorld, scope: ConfigScope = .repository, foreign: SpaceGateDecision = .clear, claimed: Bool = false) -> FakeSpaceCoordinator {
        FakeSpaceCoordinator(
            shared: [world.repositoryID: [SyncSharedScopeModel(spaceID: space, scope: scope, hasUnfinishedClaim: claimed)]],
            foreignDecision: foreign
        )
    }

    @Test func aBehindScopeIsBlockedWhileOtherScopesStillSync() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let staging = scenario.syncedEnvironment("staging", github: github)
        scenario.newItem("FXV_URL", kind: .variable, value: "https://example.com")
        scenario.newItem("FXV_STAGE_URL", kind: .variable, value: "https://staging.example.com", in: staging)
        github.addVariable(Self.marker, value: "marker-of-user-b")
        let world = ExecWorld(scenario, github: github)
        let behind = SpaceGateDecision.behind(version: 4, login: "user-b")
        let spaces = coordinator(world, foreign: behind)

        let result = try await world.sync(spaces: spaces)

        #expect(result.outcome(of: .setVariable, "FXV_URL") == .blocked(.space(SyncSpaceBlockModel(spaceID: space, decision: behind))))
        #expect(result.outcome(of: .setVariable, "FXV_STAGE_URL") == .succeeded(.verified))
        #expect(github.variable("FXV_URL") == nil)
        #expect(github.variable(Self.marker)?.value == "marker-of-user-b")
        #expect(spaces.snapshot.claims.isEmpty)
    }

    @Test func theClaimIsWrittenBeforeTheFirstWriteAndPublishedAfterTheSteps() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_URL", kind: .variable, value: "https://example.com")
        scenario.newItem("FXV_TOKEN", kind: .secret, value: "FXV_FIXTURE_TOKEN")
        let world = ExecWorld(scenario, github: github)
        let spaces = coordinator(world)

        let result = try await world.sync(spaces: spaces, spaceReason: "Rotate the token")

        #expect(github.writes.map { Array($0.prefix(3)) } == [
            ["variable", "set", Self.marker],
            ["variable", "set", "FXV_URL"],
            ["secret", "set", "FXV_TOKEN"],
            ["variable", "set", Self.marker],
        ])
        #expect(github.variable(Self.marker)?.value == "published-1")
        #expect(github.variableNames() == [Self.marker, "FXV_URL"])
        #expect(spaces.snapshot.published == [.init(spaceID: space, reason: "Rotate the token", tookOverFrom: nil)])
        #expect(spaces.snapshot.confirmed == [space])
        #expect(result.outcome(of: .setSecret, "FXV_TOKEN") == .succeeded(.verified))
        #expect(result.warnings.isEmpty)
    }

    @Test func aScopeWithoutChangesIsNotClaimed() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let staging = scenario.syncedEnvironment("staging", github: github)
        scenario.newItem("FXV_STAGE_URL", kind: .variable, value: "https://staging.example.com", in: staging)
        let world = ExecWorld(scenario, github: github)
        let spaces = coordinator(world)

        try await world.sync(spaces: spaces)

        #expect(github.variable(Self.marker) == nil)
        #expect(spaces.snapshot.claims.isEmpty)
    }

    @Test func aClaimLostOnReReadStopsTheScopeBeforeAnyWrite() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_URL", kind: .variable, value: "https://example.com")
        let world = ExecWorld(scenario, github: github)
        let publishing = SpaceGateDecision.publishing(login: "user-b", since: SteppingClock.start, isStale: false)
        let spaces = coordinator(world, foreign: publishing)
        github.afterCall(matching: GHMatch.variableSet(Self.marker)) {
            github.addVariable(Self.marker, value: "claim-of-user-b")
        }

        let result = try await world.sync(spaces: spaces)

        #expect(result.outcome(of: .setVariable, "FXV_URL") == .blocked(.space(SyncSpaceBlockModel(spaceID: space, decision: publishing))))
        #expect(github.writes.count == 1)
        #expect(github.variable("FXV_URL") == nil)
        #expect(spaces.snapshot.abandoned == [space])
        #expect(spaces.snapshot.published.isEmpty)
    }

    @Test func aDefinitiveClaimFailureFailsTheScopeAndEndsTheClaim() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_URL", kind: .variable, value: "https://example.com")
        let world = ExecWorld(scenario, github: github)
        let spaces = coordinator(world)
        github.enqueue(
            .failure(stderr: "failed to set variable \"FXVAULT_SPACE\": HTTP 403: Must have admin rights to Repository. (https://api.github.com/repos/owner-a/api/actions/variables)"),
            matching: GHMatch.variableSet(Self.marker)
        )

        let result = try await world.sync(spaces: spaces)

        #expect(result.outcome(of: .setVariable, "FXV_URL") == .failed(.github(.adminRequired)))
        #expect(github.variable("FXV_URL") == nil)
        #expect(spaces.snapshot.abandoned == [space])
        #expect(spaces.snapshot.published.isEmpty)
    }

    @Test func aStaleClaimIsTakenOverOnlyAfterConfirmation() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_URL", kind: .variable, value: "https://example.com")
        github.addVariable(Self.marker, value: "old-claim-of-user-b")
        let world = ExecWorld(scenario, github: github)
        let stale = SpaceGateDecision.publishing(login: "user-b", since: SteppingClock.start, isStale: true)
        let spaces = coordinator(world, foreign: stale)

        let review = try await world.preflightService(spaces: spaces).run(world.vault.snapshots)
        #expect(review.repositories[0].executable.isEmpty)
        #expect(review.repositories[0].spaces.map(\.decision) == [stale])

        let result = try await world.sync(spaces: spaces, takeovers: [space])

        #expect(result.outcome(of: .setVariable, "FXV_URL") == .succeeded(.verified))
        #expect(spaces.snapshot.published == [.init(spaceID: space, reason: nil, tookOverFrom: "user-b")])
        #expect(github.variable(Self.marker)?.value == "published-1")
    }

    @Test func aFailedPublishMarkerKeepsTheClaimForLaunchReconciliation() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_URL", kind: .variable, value: "https://example.com")
        let world = ExecWorld(scenario, github: github)
        let spaces = coordinator(world)
        // The first marker write (the claim) succeeds; the second (the publish) is refused.
        github.afterCall(matching: GHMatch.variableSet(Self.marker)) {
            github.enqueue(
                .failure(stderr: "failed to set variable \"FXVAULT_SPACE\": HTTP 422: Validation Failed (https://api.github.com/repos/owner-a/api/actions/variables)"),
                matching: GHMatch.variableSet(Self.marker)
            )
        }

        let result = try await world.sync(spaces: spaces)

        #expect(result.outcome(of: .setVariable, "FXV_URL") == .succeeded(.verified))
        #expect(result.warnings == [.spaceNotPublished(spaceID: space)])
        #expect(spaces.snapshot.confirmed.isEmpty)
        #expect(github.variable(Self.marker)?.value == "claim-1")
    }

    @Test func anotherMemberClaimingRightAfterThePublishIsReportedAsForked() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        scenario.newItem("FXV_URL", kind: .variable, value: "https://example.com")
        let world = ExecWorld(scenario, github: github)
        let spaces = coordinator(world)
        // The claim goes through; right after the publish, user-b's claim replaces it.
        github.afterCall(matching: GHMatch.variableSet(Self.marker)) {
            github.afterCall(matching: GHMatch.variableSet(Self.marker)) {
                github.addVariable(Self.marker, value: "claim-of-user-b")
            }
        }

        let result = try await world.sync(spaces: spaces)

        #expect(result.outcome(of: .setVariable, "FXV_URL") == .succeeded(.verified))
        #expect(result.warnings == [.spaceForked(spaceID: space)])
        #expect(spaces.snapshot.confirmed.isEmpty)
    }

    @Test func renamingASharedEnvironmentIsBlocked() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let staging = scenario.syncedEnvironment("staging", github: github)
        scenario.syncedItem("FXV_URL", kind: .variable, value: "v", syncedValue: "v", in: staging, github: github)
        scenario.environments[0].name = "stage"
        let world = ExecWorld(scenario, github: github)
        let spaces = coordinator(world, scope: .environment(staging.id))

        let review = try await world.preflightService(spaces: spaces).run(world.vault.snapshots)

        let rename = try #require(review.repositories[0].blocked.first { $0.change.kind == .renameEnvironment })
        #expect(rename.reason == .sharedEnvironment)
        #expect(review.repositories[0].executable.allSatisfy { $0.kind != .renameEnvironment })
    }

    @Test func launchReconciliationFinishesOwnClaimsAndAbandonsLostOnes() async throws {
        let github = GitHubSimulator()
        let scenario = ExecScenario()
        let staging = scenario.syncedEnvironment("staging", github: github)
        github.addVariable(Self.marker, value: "claim-of-this-mac")
        github.addVariable(Self.marker, value: "claim-of-user-b", environment: "staging")
        let world = ExecWorld(scenario, github: github)
        let other = SpaceID()
        let spaces = FakeSpaceCoordinator(
            shared: [world.repositoryID: [
                SyncSharedScopeModel(spaceID: space, scope: .repository, hasUnfinishedClaim: true),
                SyncSharedScopeModel(spaceID: other, scope: .environment(staging.id), hasUnfinishedClaim: true),
            ]],
            foreignDecision: .publishing(login: "user-b", since: SteppingClock.start, isStale: false)
        )
        spaces.markOwn("claim-of-this-mac")

        let result = await SpaceClaimReconciler(schedulers: world.registry, spaces: spaces).reconcile(world.vault.snapshots)

        #expect(result.finished == 1 && result.abandoned == 1 && result.unchecked == 0)
        #expect(spaces.snapshot.confirmed == [space])
        #expect(spaces.snapshot.abandoned == [other])
        #expect(github.variable(Self.marker)?.value == "published-0")
        #expect(github.variable(Self.marker, environment: "staging")?.value == "claim-of-user-b")
    }
}
