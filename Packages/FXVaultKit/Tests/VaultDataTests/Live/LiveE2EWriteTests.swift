import Foundation
import FXVaultTestSupport
import GitHubKit
import SyncEngine
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// The write scenario against the real GitHub (`FXV_LIVE_E2E=1 FXV_LIVE_E2E_WRITE=1`, see
/// ``LiveE2E``). Creates (or reuses) the public `<account>/fx-vault-e2e`, runs create → verify →
/// edit/rename → drift → clone/export → spike facts, then deletes every environment, secret and
/// variable it holds. The repository itself stays (no `delete_repo` scope).
@Suite("Live E2E (writes to GitHub, opt-in)", .enabled(if: LiveE2E.isWriteEnabled), .serialized, .timeLimit(.minutes(30)))
struct LiveE2EWriteTests {
    private func makeReport(_ world: E2EWorld) -> LiveE2EReport {
        var replacements = [(world.accountLogin, "owner-a")]
        if let org = LiveE2E.freeOrganization {
            replacements.append((org, "Example-Org"))
        }
        return LiveE2EReport(replacements: replacements)
    }

    @Test func publicRepositoryScenario() async throws {
        let world = try await E2EWorld.live()
        defer { world.remove() }
        let report = makeReport(world)
        defer { report.write() }
        let scenario = E2EScenario(world: world, owner: world.accountLogin, name: LiveE2E.publicRepositoryName, report: report)
        var repositoryID: RepoID?
        var failure: (any Error)?
        do {
            let id = try await scenario.createOrImport()
            repositoryID = id
            try await scenario.verify(E2EData.created, repositoryID: id, step: "create")
            try await scenario.editDeleteRename(id)
            try await scenario.verify(E2EData.edited, repositoryID: id, step: "edit")
            try await scenario.driftFromATeammate(id)
            var drifted = E2EData.edited
            drifted.variables["FXV_E2E_REGION"] = "teammate-region"
            try await scenario.verify(drifted, repositoryID: id, step: "drift")
            try await scenario.cloneThroughAlias(id)
            try await E2ESpike(probe: world.probe, fullName: scenario.fullName, report: report).run()
        } catch {
            failure = error
        }
        try await scenario.cleanUp(repositoryID)
        if let failure { throw failure }
    }

    /// Step 7: a private repository on a Free organization. Records what gh prints for the
    /// plan-gated parts and checks that what failed stays pending.
    @Test(.enabled(if: LiveE2E.freeOrganization != nil))
    func planGatedPrivateRepository() async throws {
        let org = try #require(LiveE2E.freeOrganization)
        let world = try await E2EWorld.live()
        defer { world.remove() }
        let report = makeReport(world)
        defer { report.write() }
        let scenario = E2EScenario(world: world, owner: org, name: LiveE2E.freeRepositoryName, report: report)
        var repositoryID: RepoID?
        var failure: (any Error)?
        do {
            repositoryID = try await planGatedRun(scenario)
            try await recordPlanGatedStderr(scenario)
        } catch {
            failure = error
        }
        try await scenario.cleanUp(repositoryID)
        if let failure { throw failure }
    }

    private func planGatedRun(_ scenario: E2EScenario) async throws -> RepoID {
        let world = scenario.world
        let environment = RepoCreationEnvironmentDraftModel(
            name: E2EData.production,
            policy: .custom([BranchPatternDraftModel(pattern: "main", type: .branch)]),
            items: [E2EData.item(.secret, "FXV_E2E_FREE_TOKEN", "fxv-e2e-free-token")]
        )
        let id: RepoID
        if try await world.probe.repositoryExists(scenario.fullName) {
            let ref = try GHRepoRef(owner: scenario.owner, name: scenario.name)
            id = try await world.catalog.importRepository(ref, accountLogin: world.accountLogin).repository.id
            try scenario.deleteEverything(in: id)
            if try world.pendingCount() > 0 { _ = try await world.runSync() }
            let environmentID = try world.config.createEnvironment(in: id, name: environment.name, policy: environment.policy)
            for item in environment.items {
                try world.config.addItem(repositoryID: id, scope: .environment(environmentID), kind: item.kind, name: item.name, value: item.value)
            }
            try world.config.addItem(repositoryID: id, scope: .repository, kind: .variable, name: "FXV_E2E_FREE_REGION", value: SecretBytes(utf8: "me-central-1"))
        } else {
            id = try await world.creation.stage(RepoCreationDraftModel(
                accountLogin: world.accountLogin,
                ownerLogin: scenario.owner,
                ownerType: .organization,
                name: scenario.name,
                description: "FX Vault plan-gating test repository (synthetic values only)",
                visibility: .private,
                spec: RepoCreateSpecModel(autoInit: false, gitignoreTemplate: nil, licenseTemplate: nil, cloneAfter: false),
                items: [E2EData.item(.variable, "FXV_E2E_FREE_REGION", "me-central-1")],
                environments: [environment]
            )).repositoryID
        }
        let outcome = try await world.runSync()
        for entry in outcome.result.entries {
            scenario.report.record("step7.outcome.\(entry.change.id)", String(describing: entry.outcome))
        }
        #expect(outcome.result.stopReason == nil)
        #expect(try world.repository(scenario.fullName).githubID != nil, "the private repository was not created")
        let notSucceeded = outcome.result.entries.filter { !$0.outcome.isSucceeded }
        // Whatever GitHub refused stays pending for the next Sync.
        #expect(try world.pendingCount() >= notSucceeded.count)
        for entry in notSucceeded {
            if case .failed(.github(let error)) = entry.outcome {
                #expect(error == .planGated, "\(entry.change.id) failed with \(error.logCode), expected plan_gated")
            }
        }
        scenario.report.record("step7.isEnvPlanGated", String(try world.repository(scenario.fullName).isEnvPlanGated))
        return id
    }

    /// The raw gh output of each plan-gated call, and how the classifier reads it.
    private func recordPlanGatedStderr(_ scenario: E2EScenario) async throws {
        let probe = scenario.world.probe
        let fullName = scenario.fullName
        let spike = E2ESpike(probe: probe, fullName: fullName, report: scenario.report)
        try await spike.recordCall(
            "step7.envPutCustomPolicy",
            operation: .environmentUpsert,
            ["api"] + GHProbe.apiHeaders + ["-X", "PUT", "-i", "repos/\(fullName)/environments/fxv-e2e-probe", "--input", "-"],
            stdin: #"{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}"#
        )
        try await spike.recordCall(
            "step7.envPutNoPolicy",
            operation: .environmentUpsert,
            ["api"] + GHProbe.apiHeaders + ["-X", "PUT", "-i", "repos/\(fullName)/environments/fxv-e2e-probe", "--input", "-"],
            stdin: #"{"deployment_branch_policy":null}"#
        )
        try await spike.recordCall(
            "step7.branchPolicyAdd",
            operation: .branchPolicyAdd,
            ["api"] + GHProbe.apiHeaders + ["-X", "POST", "-i", "repos/\(fullName)/environments/fxv-e2e-probe/deployment-branch-policies", "--input", "-"],
            stdin: #"{"name":"main","type":"branch"}"#
        )
        try await spike.recordCall(
            "step7.envSecretSet",
            operation: .secretSet,
            ["secret", "set", "FXV_E2E_PROBE", "--repo=\(fullName)", "--env=fxv-e2e-probe"],
            stdin: "fxv-e2e-probe-value"
        )
        try await spike.recordCall(
            "step7.envVariableSet",
            operation: .variableSet,
            ["variable", "set", "FXV_E2E_PROBE", "--repo=\(fullName)", "--env=fxv-e2e-probe"],
            stdin: "fxv-e2e-probe-value"
        )
    }
}

/// Spike facts of tasks/todo.md §11 M3 (Q6), recorded on the public scenario repository with
/// raw gh calls. Facts go to the report; only invariants the engine relies on are asserted.
struct E2ESpike {
    let probe: GHProbe
    let fullName: String
    let report: LiveE2EReport

    private static let environment = "fxv-e2e-spike"

    /// Leftovers of a failed run are removed by ``E2EScenario/cleanUp(_:)`` (everything listed).
    func run() async throws {
        try await identicalSets()
        try await valueNormalization()
        try await environmentBehavior()
        await Self.cleanUp(probe: probe, fullName: fullName)
    }

    /// Q6: does an identical-value set move `updatedAt`?
    private func identicalSets() async throws {
        let secret = "FXV_E2E_SPIKE_SECRET"
        try await set(["secret", "set", secret, "--repo=\(fullName)"], "fxv-e2e-same-value")
        let secretBefore = try await probe.secrets(fullName)[secret]
        try await Task.sleep(for: LiveE2E.timestampTick)
        try await set(["secret", "set", secret, "--repo=\(fullName)"], "fxv-e2e-same-value")
        let secretAfter = try await probe.secrets(fullName)[secret]
        report.record("q6.secretIdenticalSet", "updatedAt \(secretBefore ?? "-") -> \(secretAfter ?? "-")")
        // The executor verifies a secret by a moved updatedAt (§7.3 step 6).
        #expect(secretBefore != secretAfter, "an identical secret set did not move updatedAt: verification would stay pending")

        let variable = "FXV_E2E_SPIKE_VARIABLE"
        try await set(["variable", "set", variable, "--repo=\(fullName)"], "fxv-e2e-same-value")
        let variableBefore = try await probe.variableTimestamps(fullName)[variable]
        try await Task.sleep(for: LiveE2E.timestampTick)
        try await set(["variable", "set", variable, "--repo=\(fullName)"], "fxv-e2e-same-value")
        let variableAfter = try await probe.variableTimestamps(fullName)[variable]
        report.record("q6.variableIdenticalSet", "updatedAt \(variableBefore ?? "-") -> \(variableAfter ?? "-")")
    }

    /// Value normalization through gh (D32) and empty values.
    private func valueNormalization() async throws {
        let cases: [(String, String)] = [
            ("FXV_E2E_SPIKE_CRLF", "fxv-e2e-crlf\r\n"),
            ("FXV_E2E_SPIKE_LF2", "fxv-e2e-two-lf\n\n"),
            ("FXV_E2E_SPIKE_SPACES", "  fxv e2e spaces  "),
            ("FXV_E2E_SPIKE_INNER_LF", "line one\nline two"),
        ]
        for (name, value) in cases {
            try await set(["variable", "set", name, "--repo=\(fullName)"], value)
        }
        let listed = try await probe.variables(fullName)
        for (name, value) in cases {
            report.record("normalization.\(name)", "sent \(value.debugDescription) listed \((listed[name] ?? "<absent>").debugDescription)")
        }
        #expect(listed["FXV_E2E_SPIKE_CRLF"] == "fxv-e2e-crlf", "gh no longer strips a trailing CRLF (D32)")
        #expect(listed["FXV_E2E_SPIKE_SPACES"] == "  fxv e2e spaces  ", "GitHub changed surrounding spaces of a variable")
        #expect(listed["FXV_E2E_SPIKE_INNER_LF"] == "line one\nline two")

        try await recordCall("empty.variableSet", operation: .variableSet, ["variable", "set", "FXV_E2E_SPIKE_EMPTY", "--repo=\(fullName)"], stdin: "")
        try await recordCall("empty.secretSet", operation: .secretSet, ["secret", "set", "FXV_E2E_SPIKE_EMPTY", "--repo=\(fullName)"], stdin: "")
        try await recordCall("missing.secretDelete", operation: .secretDelete, ["secret", "delete", "FXV_E2E_SPIKE_MISSING", "--repo=\(fullName)"])
        try await recordCall("missing.variableDelete", operation: .variableDelete, ["variable", "delete", "FXV_E2E_SPIKE_MISSING", "--repo=\(fullName)"])
    }

    /// Environment PUT/DELETE semantics and the already-existing branch policy POST (C3).
    private func environmentBehavior() async throws {
        let path = "repos/\(fullName)/environments/\(Self.environment)"
        let put = ["api"] + GHProbe.apiHeaders + ["-X", "PUT", "-i", path, "--input", "-"]
        try await recordCall("env.put422BothFlags", operation: .environmentUpsert, put,
                             stdin: #"{"deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":true}}"#)
        try await requireCall(put, stdin: #"{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}"#)
        let post = ["api"] + GHProbe.apiHeaders + ["-X", "POST", "-i", "\(path)/deployment-branch-policies", "--input", "-"]
        try await recordCall("c3.first", operation: .branchPolicyAdd, post, stdin: #"{"name":"spike/*","type":"branch"}"#)
        try await recordCall("c3.duplicate", operation: .branchPolicyAdd, post, stdin: #"{"name":"spike/*","type":"branch"}"#)
        let policies = try await probe.branchPolicies(fullName, environment: Self.environment)
        #expect(policies == ["spike/*|branch"], "a duplicate POST created a second policy")

        // Fields omitted from a PUT: are existing reviewers kept?
        let user = try await probe.run(["api", "user", "--jq", ".id"])
        if user.isSuccess, let id = Int64(user.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            try await requireCall(put, stdin: #"{"reviewers":[{"type":"User","id":\#(id)}],"deployment_branch_policy":null}"#)
            try await requireCall(put, stdin: #"{"deployment_branch_policy":null}"#)
            let get = try await probe.run(["api"] + GHProbe.apiHeaders + ["-X", "GET", path])
            let kept = get.stdout.contains("\"required_reviewers\"")
            report.record("env.putKeepsReviewers", kept ? "yes" : "no")
            #expect(kept, "a PUT without reviewers removed them: C2 would drop a teammate's reviewers")
        }

        // DELETE of an environment and its secrets.
        try await set(["secret", "set", "FXV_E2E_SPIKE_ENV", "--repo=\(fullName)", "--env=\(Self.environment)"], "fxv-e2e-env-value")
        try await recordCall("c9.delete", operation: .environmentDelete, ["api"] + GHProbe.apiHeaders + ["-X", "DELETE", "-i", path])
        try await recordCall("c9.deleteMissing", operation: .environmentDelete, ["api"] + GHProbe.apiHeaders + ["-X", "DELETE", "-i", path])
        try await requireCall(put, stdin: #"{"deployment_branch_policy":null}"#)
        let secrets = try await probe.secrets(fullName, environment: Self.environment)
        report.record("c9.deleteRemovesSecrets", secrets.isEmpty ? "yes" : "no (\(secrets.count) left)")
        #expect(secrets.isEmpty, "a re-created environment still has the deleted one's secrets")
    }

    // MARK: Helpers

    private func set(_ arguments: [String], _ value: String) async throws {
        try await requireCall(arguments, stdin: value)
    }

    private func requireCall(_ arguments: [String], stdin: String? = nil) async throws {
        let result = try await probe.run(arguments, stdin: stdin)
        try #require(result.isSuccess, "gh \(arguments.prefix(2).joined(separator: " ")) failed: \(report.sanitize(result.stderr))")
    }

    /// Runs a call that may fail and records its exit code, `-i` status, stderr and class.
    func recordCall(_ key: String, operation: GHOperation, _ arguments: [String], stdin: String? = nil) async throws {
        let result = try await probe.run(arguments, stdin: stdin)
        let status = APIResponseParser.statusIfPresent(in: Data(result.stdout.utf8))
        var entry = "exit \(result.exitCode); status \(status.map(String.init) ?? "-"); stderr \(result.stderr.debugDescription)"
        if !result.isSuccess {
            let error = GHStderrClassifier.classify(GHFailureContext(
                operation: operation,
                exitCode: result.exitCode,
                stderr: StderrRedactor.redactTokenPatterns(in: result.stderr),
                responseStatus: status
            ))
            entry += "; classified \(error.logCode)"
        }
        report.record(key, entry)
    }

    static func cleanUp(probe: GHProbe, fullName: String) async {
        _ = try? await probe.run(["api"] + GHProbe.apiHeaders + ["-X", "DELETE", "repos/\(fullName)/environments/\(environment)"])
        let names = ["FXV_E2E_SPIKE_SECRET", "FXV_E2E_SPIKE_EMPTY"]
        for name in names {
            _ = try? await probe.run(["secret", "delete", name, "--repo=\(fullName)"])
        }
        let variables = [
            "FXV_E2E_SPIKE_VARIABLE", "FXV_E2E_SPIKE_CRLF", "FXV_E2E_SPIKE_LF2", "FXV_E2E_SPIKE_SPACES",
            "FXV_E2E_SPIKE_INNER_LF", "FXV_E2E_SPIKE_EMPTY",
        ]
        for name in variables {
            _ = try? await probe.run(["variable", "delete", name, "--repo=\(fullName)"])
        }
    }
}

/// The write scenario against `GitHubSimulator`, in every `swift test` run: it keeps the live
/// scenario's own logic honest (the live suite cannot run in CI) and drives the whole engine
/// end to end (stage → create → edit/rename → drift → clone → delete everything).
@Suite("E2E scenario dry run (simulated GitHub)", .serialized, .timeLimit(.minutes(2)))
struct E2EScenarioDryRunTests {
    @Test func scenarioPassesAgainstTheSimulator() async throws {
        let simulator = GitHubSimulator(owner: SyncFixture.login, name: LiveE2E.publicRepositoryName, exists: false, visibility: .public)
        let world = try await E2EWorld.simulated(simulator)
        defer { world.remove() }
        let scenario = E2EScenario(world: world, owner: SyncFixture.login, name: LiveE2E.publicRepositoryName, report: LiveE2EReport(replacements: []))

        let id = try await scenario.createOrImport()
        #expect(simulator.repositoryExists)
        let create = try #require(simulator.calls.first { $0.starts(with: ["repo", "create"]) })
        #expect(create.contains("--public") && create.contains("--add-readme") && create.contains("--license=mit"))
        #expect(simulator.secret("FXV_E2E_PEM")?.value == String(E2EData.pem.dropLast()))
        try await scenario.verify(E2EData.created, repositoryID: id, step: "create")
        try await scenario.editDeleteRename(id)
        try await scenario.verify(E2EData.edited, repositoryID: id, step: "edit")
        try await scenario.driftFromATeammate(id)
        var drifted = E2EData.edited
        drifted.variables["FXV_E2E_REGION"] = "teammate-region"
        try await scenario.verify(drifted, repositoryID: id, step: "drift")
        try await scenario.cloneThroughAlias(id)
        // The guided rename recreated `stage` with both patterns; `staging` is gone.
        #expect(simulator.environment(E2EData.staging) == nil)
        #expect(simulator.environment(E2EData.stage)?.patterns.count == 2)
        try await scenario.cleanUp(id)
        #expect(simulator.environmentNames.isEmpty)
        #expect(simulator.secretNames().isEmpty && simulator.variableNames().isEmpty)
        #expect(simulator.writes.count > 30)
        #expect(try world.pendingCount() == 0)
    }

    @Test func anExistingRepositoryIsImportedAndReset() async throws {
        let simulator = GitHubSimulator(owner: SyncFixture.login, name: LiveE2E.publicRepositoryName, exists: true, visibility: .public)
        // Leftovers of an interrupted earlier run.
        simulator.addEnvironment(E2EData.stage, policy: .custom, patterns: [("release/*", .branch)])
        simulator.addSecret("FXV_E2E_STAGING_TOKEN", environment: E2EData.stage)
        simulator.addSecret("FXV_E2E_API_TOKEN")
        simulator.addVariable("FXV_E2E_REGION", value: "stale-region")
        let world = try await E2EWorld.simulated(simulator)
        defer { world.remove() }
        let report = LiveE2EReport(replacements: [])
        let scenario = E2EScenario(world: world, owner: SyncFixture.login, name: LiveE2E.publicRepositoryName, report: report)

        let id = try await scenario.createOrImport()
        #expect(report.snapshot["step2.path"] == "imported (existing repository)")
        try await scenario.verify(E2EData.created, repositoryID: id, step: "import + reset")
        try await scenario.cleanUp(id)
    }
}
