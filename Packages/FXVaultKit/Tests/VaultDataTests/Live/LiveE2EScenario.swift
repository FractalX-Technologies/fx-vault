import EnvTools
import Foundation
import GitHubKit
import SyncEngine
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// What GitHub (and the vault) must hold after a step. Variable values are the normalized ones
/// (D32: no trailing CR/LF). All values are synthetic.
struct E2EExpectedState {
    struct Environment {
        var policy: BranchPolicyDraftModel
        var secrets: Set<String>
        var variables: [String: String]
    }

    var secrets: Set<String>
    var variables: [String: String]
    var environments: [String: Environment]
}

/// Synthetic data of the write scenario (`FXV_E2E_*`, tasks/lessons.md).
enum E2EData {
    /// A PEM-shaped multi-line value ending in a newline (stripped on entry, D32).
    static let pem = "-----BEGIN FXV E2E SYNTHETIC KEY-----\nRlhWX0UyRV9TWU5USEVUSUNfT05MWQ==\nRlhWX0UyRV9OT1RfQV9LRVk=\n-----END FXV E2E SYNTHETIC KEY-----\n"
    static let phrase = "fxv e2e phrase with  inner spaces"
    static let unicode = "مرحبا — café ✓ 🚀 Producción"
    static let padded = "  fxv e2e padded value  "

    static let staging = "staging"
    static let stage = "stage"
    static let production = "production"

    static let stagingPolicy = BranchPolicyDraftModel.custom([
        BranchPatternDraftModel(pattern: "release/*", type: .branch),
        BranchPatternDraftModel(pattern: "v*", type: .tag),
    ])

    static func item(_ kind: ConfigKind, _ name: String, _ value: String) -> RepoCreationItemDraftModel {
        RepoCreationItemDraftModel(kind: kind, name: name, value: SecretBytes(utf8: value))
    }

    static var repositoryItems: [RepoCreationItemDraftModel] {
        [
            item(.secret, "FXV_E2E_API_TOKEN", "fxv-e2e-token-1"),
            item(.secret, "FXV_E2E_PEM", pem),
            item(.secret, "FXV_E2E_PHRASE", phrase),
            item(.variable, "FXV_E2E_REGION", "me-central-1"),
            item(.variable, "FXV_E2E_GREETING", unicode),
            item(.variable, "FXV_E2E_PADDED", padded),
        ]
    }

    static var environments: [RepoCreationEnvironmentDraftModel] {
        [
            RepoCreationEnvironmentDraftModel(name: staging, policy: stagingPolicy, items: [
                item(.secret, "FXV_E2E_STAGING_TOKEN", "fxv-e2e-staging-token"),
                item(.variable, "FXV_E2E_STAGING_URL", "https://staging.example.invalid"),
            ]),
            RepoCreationEnvironmentDraftModel(name: production, policy: .protectedBranches, items: [
                item(.secret, "FXV_E2E_PROD_TOKEN", "fxv-e2e-prod-token"),
                item(.variable, "FXV_E2E_PROD_URL", "https://example.invalid"),
            ]),
        ]
    }

    static var created: E2EExpectedState {
        E2EExpectedState(
            secrets: ["FXV_E2E_API_TOKEN", "FXV_E2E_PEM", "FXV_E2E_PHRASE"],
            variables: ["FXV_E2E_REGION": "me-central-1", "FXV_E2E_GREETING": unicode, "FXV_E2E_PADDED": padded],
            environments: [
                staging: .init(
                    policy: stagingPolicy,
                    secrets: ["FXV_E2E_STAGING_TOKEN"],
                    variables: ["FXV_E2E_STAGING_URL": "https://staging.example.invalid"]
                ),
                production: .init(
                    policy: .protectedBranches,
                    secrets: ["FXV_E2E_PROD_TOKEN"],
                    variables: ["FXV_E2E_PROD_URL": "https://example.invalid"]
                ),
            ]
        )
    }

    /// After step 4: edited region and token, deleted phrase and production URL, greeting
    /// renamed to welcome, staging renamed to stage.
    static var edited: E2EExpectedState {
        var state = created
        state.secrets.remove("FXV_E2E_PHRASE")
        state.variables["FXV_E2E_REGION"] = "eu-west-1"
        state.variables["FXV_E2E_GREETING"] = nil
        state.variables["FXV_E2E_WELCOME"] = unicode
        state.environments[production]?.variables = [:]
        state.environments[stage] = state.environments.removeValue(forKey: staging)
        return state
    }
}

/// The write scenario (tasks/todo.md §11 M3/M4/M5 "done when", run as one story). The same code
/// runs against the real GitHub (``LiveE2EWriteTests``) and the simulator
/// (``E2EScenarioDryRunTests``).
struct E2EScenario {
    let world: E2EWorld
    let owner: String
    let name: String
    let report: LiveE2EReport

    var fullName: String {
        "\(owner)/\(name)"
    }

    /// Lets GitHub's second-granularity `updatedAt` move between two writes of one item.
    func waitForNextSecond() async throws {
        guard world.isLive else { return }
        try await Task.sleep(for: LiveE2E.timestampTick)
    }

    // MARK: Step 2: create (or import and reset)

    @discardableResult
    func createOrImport() async throws -> RepoID {
        if try await world.probe.repositoryExists(fullName) {
            report.record("step2.path", "imported (existing repository)")
            return try await importAndReset()
        }
        report.record("step2.path", "created")
        let availability = await world.creation.checkAvailability(owner: owner, name: name, accountLogin: world.accountLogin)
        #expect(availability == .probablyAvailable)
        let staged = try await world.creation.stage(RepoCreationDraftModel(
            accountLogin: world.accountLogin,
            ownerLogin: owner,
            ownerType: .user,
            name: name,
            description: "FX Vault end-to-end test repository (synthetic values only)",
            visibility: .public,
            spec: RepoCreateSpecModel(autoInit: true, gitignoreTemplate: "Swift", licenseTemplate: "mit", cloneAfter: false),
            items: E2EData.repositoryItems,
            environments: E2EData.environments
        ))
        #expect(staged.strippedTrailingNewlines == ["FXV_E2E_PEM"])
        #expect(try world.pendingCount() > 0)
        let outcome = try await world.runSync()
        expectClean(outcome, "create")
        let repository = try world.repository(fullName)
        #expect(repository.githubID != nil)
        #expect(repository.origin == .created)
        return repository.id
    }

    /// A repository left by an earlier run: import it, delete everything in it with one Sync,
    /// then add the scenario's state with a second Sync.
    private func importAndReset() async throws -> RepoID {
        let ref = try GHRepoRef(owner: owner, name: name)
        let imported = try await world.catalog.importRepository(ref, accountLogin: world.accountLogin)
        #expect(imported.unreadable.isEmpty)
        let id = imported.repository.id
        try deleteEverything(in: id)
        if try world.pendingCount() > 0 {
            expectClean(try await world.runSync(), "reset")
        }
        for item in E2EData.repositoryItems {
            try world.config.addItem(repositoryID: id, scope: .repository, kind: item.kind, name: item.name, value: item.value)
        }
        for environment in E2EData.environments {
            let environmentID = try world.config.createEnvironment(in: id, name: environment.name, policy: environment.policy)
            for item in environment.items {
                try world.config.addItem(repositoryID: id, scope: .environment(environmentID), kind: item.kind, name: item.name, value: item.value)
            }
        }
        expectClean(try await world.runSync(), "re-create")
        return id
    }

    func deleteEverything(in id: RepoID) throws {
        for environment in try world.store.fetchEnvironments(repositoryID: id) where !environment.isDeleted {
            try world.config.deleteEnvironment(environment.id)
        }
        for item in try world.liveItems(id, scope: .repository) {
            try world.config.deleteItem(item.id)
        }
    }

    // MARK: Step 3: verify independently

    func verify(_ expected: E2EExpectedState, repositoryID: RepoID, step: String) async throws {
        let probe = world.probe
        #expect(Set(try await probe.secrets(fullName).keys) == expected.secrets, "\(step): repository secrets")
        let variables = try await probe.variables(fullName)
        #expect(Set(variables.keys) == Set(expected.variables.keys), "\(step): repository variable names")
        for (key, value) in expected.variables {
            #expect(variables[key] == value, "\(step): value of \(key) as listed by gh differs")
        }

        let environments = try await probe.environments(fullName)
        #expect(Set(environments.keys) == Set(expected.environments.keys), "\(step): environment names")
        for (environmentName, expectedEnvironment) in expected.environments {
            let flags = environments[environmentName] ?? nil
            switch expectedEnvironment.policy {
            case .all:
                #expect(flags == nil, "\(step): \(environmentName) policy")
            case .protectedBranches:
                #expect(flags?.protected == true && flags?.custom == false, "\(step): \(environmentName) policy")
            case .custom(let patterns):
                #expect(flags?.protected == false && flags?.custom == true, "\(step): \(environmentName) policy")
                let listed = try await probe.branchPolicies(fullName, environment: environmentName)
                #expect(listed == Set(patterns.map { "\($0.pattern)|\($0.type.rawValue)" }), "\(step): \(environmentName) patterns")
            }
            #expect(Set(try await probe.secrets(fullName, environment: environmentName).keys) == expectedEnvironment.secrets,
                    "\(step): \(environmentName) secrets")
            let environmentVariables = try await probe.variables(fullName, environment: environmentName)
            #expect(Set(environmentVariables.keys) == Set(expectedEnvironment.variables.keys), "\(step): \(environmentName) variable names")
            for (key, value) in expectedEnvironment.variables {
                #expect(environmentVariables[key] == value, "\(step): value of \(environmentName)/\(key) differs")
            }
        }
        try verifyVault(expected, repositoryID: repositoryID, step: step)
    }

    /// Every row synced and verified, nothing pending, ids recorded.
    func verifyVault(_ expected: E2EExpectedState, repositoryID: RepoID, step: String) throws {
        #expect(try world.pendingCount() == 0, "\(step): pending changes left")
        let liveEnvironments = try world.store.fetchEnvironments(repositoryID: repositoryID).filter { !$0.isDeleted }
        #expect(Set(liveEnvironments.map(\.name)) == Set(expected.environments.keys), "\(step): vault environments")
        for environment in liveEnvironments {
            #expect(environment.githubEnvID != nil, "\(step): \(environment.name) has no GitHub id")
            #expect(environment.syncedName == environment.name)
            #expect(environment.syncedBranchPolicy == environment.branchPolicy.kind)
            for pattern in environment.branchPolicy.activePatterns {
                #expect(pattern.githubPolicyID != nil, "\(step): pattern \(pattern.pattern) has no GitHub id")
            }
        }
        var scopes: [(ConfigScope, Set<String>)] = [(.repository, expected.secrets.union(expected.variables.keys))]
        for environment in liveEnvironments {
            let expectedEnvironment = expected.environments[environment.name]
            scopes.append((
                .environment(environment.id),
                (expectedEnvironment?.secrets ?? []).union(expectedEnvironment?.variables.keys.map { $0 } ?? [])
            ))
        }
        for (scope, names) in scopes {
            let rows = try world.liveItems(repositoryID, scope: scope)
            #expect(Set(rows.map(\.name)) == names, "\(step): vault rows of \(scope)")
            for row in rows {
                #expect(row.verifyState == .verified, "\(step): \(row.name) verify_state")
                #expect(row.syncedName == row.name, "\(step): \(row.name) synced_name")
                #expect(!row.forcePush, "\(step): \(row.name) force_push")
                #expect(row.hasSyncedValue || row.kind == .secret, "\(step): \(row.name) synced value")
                #expect(row.valueFingerprint == row.syncedFingerprint, "\(step): \(row.name) is not synced")
                if row.kind == .secret {
                    #expect(row.remoteUpdatedAt != nil, "\(step): \(row.name) remote_updated_at")
                }
            }
        }
    }

    // MARK: Step 4: edit, delete, rename item, rename environment

    func editDeleteRename(_ id: RepoID) async throws {
        let before = try await world.probe.secrets(fullName)
        try await waitForNextSecond()
        try world.config.editValue(try world.item("FXV_E2E_REGION", kind: .variable, in: id).id, value: SecretBytes(utf8: "eu-west-1"))
        try world.config.editValue(try world.item("FXV_E2E_API_TOKEN", kind: .secret, in: id).id, value: SecretBytes(utf8: "fxv-e2e-token-2"))
        try world.config.deleteItem(try world.item("FXV_E2E_PHRASE", kind: .secret, in: id).id)
        let production = try #require(try world.environment(E2EData.production, in: id))
        try world.config.deleteItem(try world.item("FXV_E2E_PROD_URL", kind: .variable, in: id, scope: .environment(production.id)).id)
        try world.config.renameItem(try world.item("FXV_E2E_GREETING", kind: .variable, in: id).id, to: "FXV_E2E_WELCOME")
        let staging = try #require(try world.environment(E2EData.staging, in: id))
        #expect(try world.config.renameEnvironment(staging.id, to: E2EData.stage) == .recreateOnGitHub)

        let review = try await world.sync.preflight()
        #expect(review.preflight.repositories.flatMap(\.blocked).isEmpty)
        #expect(review.deletionCount >= 2)
        let preview = await world.sync.deletionPreview(for: review)
        #expect(preview.flatMap(\.itemDeletions).count >= 2)
        let first = await (try await world.sync.startRun(review, includeDeletions: true)).outcome()
        expectClean(first, "edit + guided rename")
        // The guided rename leaves the old environment as a tombstone: the next Sync deletes it.
        let tombstone = try world.store.fetchEnvironments(repositoryID: id).first { $0.isDeleted && $0.name == E2EData.staging }
        #expect(tombstone != nil, "the old environment is not pending deletion")
        expectClean(try await world.runSync(), "delete old environment")

        let after = try await world.probe.secrets(fullName)
        #expect(after["FXV_E2E_API_TOKEN"] != before["FXV_E2E_API_TOKEN"], "the edited secret's updatedAt did not move")
        #expect(after["FXV_E2E_PEM"] == before["FXV_E2E_PEM"], "an unchanged secret was written")
    }

    // MARK: Step 5: drift

    func driftFromATeammate(_ id: RepoID) async throws {
        try await waitForNextSecond()
        let probe = world.probe
        let variable = try await probe.run(["variable", "set", "FXV_E2E_REGION", "--repo=\(fullName)"], stdin: "teammate-region")
        #expect(variable.isSuccess, "teammate variable set: \(report.sanitize(variable.stderr))")
        let secret = try await probe.run(["secret", "set", "FXV_E2E_API_TOKEN", "--repo=\(fullName)"], stdin: "teammate-token")
        #expect(secret.isSuccess, "teammate secret set: \(report.sanitize(secret.stderr))")
        let teammateSecretTimestamp = try await probe.secrets(fullName)["FXV_E2E_API_TOKEN"]

        let report = try await world.drift.refresh(id)
        #expect(report.unreadable.isEmpty)
        #expect(Set(report.drifts.map(\.kind)) == [.variableModified, .secretModified], "drift kinds: \(report.drifts.map(\.kind))")
        #expect(report.drifts.count == 2)
        #expect(report.conflicts.isEmpty)
        let variableDrift = try #require(report.drifts.first { $0.kind == .variableModified })
        let secretDrift = try #require(report.drifts.first { $0.kind == .secretModified })
        guard case .item(let variableSubject) = variableDrift.subject, case .item(let secretSubject) = secretDrift.subject else {
            Issue.record("item drifts expected")
            return
        }
        #expect(variableSubject.name == "FXV_E2E_REGION")
        #expect(secretSubject.name == "FXV_E2E_API_TOKEN")

        try await world.drift.resolve(variableDrift, option: .acceptGitHub)
        try await world.drift.resolve(secretDrift, option: .keepLocal)
        #expect(try world.localValue(try world.item("FXV_E2E_REGION", kind: .variable, in: id).id) == "teammate-region")
        #expect(try world.item("FXV_E2E_API_TOKEN", kind: .secret, in: id).forcePush)
        #expect(try world.pendingCount() == 1)

        try await waitForNextSecond()
        expectClean(try await world.runSync(), "push after drift")
        #expect(try await probe.variables(fullName)["FXV_E2E_REGION"] == "teammate-region")
        #expect(try await probe.secrets(fullName)["FXV_E2E_API_TOKEN"] != teammateSecretTimestamp, "keep local did not push")
        let again = try await world.drift.refresh(id)
        #expect(again.drifts.isEmpty, "drift after resolving: \(again.drifts.map(\.kind))")
    }

    // MARK: Step 6: clone through the alias

    func cloneThroughAlias(_ id: RepoID) async throws {
        let alias = LiveE2E.sshAlias
        if let github = world.github {
            try await github.mapSSHAlias(alias, to: world.accountLogin)
        } else {
            let accounts = AccountStore(database: world.database)
            var account = try #require(try accounts.fetch(login: world.accountLogin))
            account.sshHostAlias = alias
            try accounts.save(account)
        }
        let folder = world.directory.directory("clones")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try await world.creation.clone(id, into: folder)
        #expect(destination.lastPathComponent == name)
        #expect(try world.repository(fullName).clonePath == destination.path)
        guard world.isLive else { return }
        let remote = try await LiveGit.run(["remote", "get-url", "origin"], in: destination)
        #expect(remote == GitService.cloneURL(alias: alias, repo: try GHRepoRef(owner: owner, name: name)))
        if report.snapshot["step2.path"] == "created" {
            for file in ["README.md", "LICENSE", ".gitignore"] {
                #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(file).path), "\(file) missing")
            }
        }
        // An environment exported into the clone, checked against the template's real `.gitignore`.
        let production = try #require(try world.environment(E2EData.production, in: id))
        let exportURL = destination.appendingPathComponent(".env")
        let destinationCheck = await world.envFiles.inspectDestination(exportURL)
        let exposure = try #require(destinationCheck.gitExposure, "the git check failed in the clone")
        report.record("step6.envExposedInClone", String(exposure.isExposed))
        let authorization = try await ReauthGate(manager: world.manager)
            .authorizeEnvExport(with: .password(LiveE2E.password), session: world.session)
        let exported = try world.envFiles.export(
            repositoryID: id,
            scope: .environment(production.id),
            to: exportURL,
            authorization: authorization
        )
        #expect(exported.preview.exportedNames == ["FXV_E2E_PROD_TOKEN"])
        if exposure.isExposed {
            #expect(try world.envFiles.addGitignoreEntry(relativePath: ".env", repositoryRoot: destination))
        }
        let fixed = await world.envFiles.inspectDestination(exportURL)
        #expect(fixed.gitExposure?.isExposed == false)
    }

    // MARK: Step 8: clean up

    /// Deletes every environment, secret and variable through the engine (C6, C8, C9), then
    /// checks with gh that nothing is left, and removes leftovers directly.
    func cleanUp(_ id: RepoID?) async throws {
        if let id {
            try deleteEverything(in: id)
            if try world.pendingCount() > 0 {
                expectClean(try await world.runSync(), "clean up")
            }
        }
        try await removeLeftovers()
        #expect(try await world.probe.secrets(fullName).isEmpty)
        #expect(try await world.probe.variables(fullName).isEmpty)
        #expect(try await world.probe.environments(fullName).isEmpty)
    }

    /// Direct gh deletes for anything the engine left (a failed run).
    func removeLeftovers() async throws {
        let probe = world.probe
        for environment in try await probe.environments(fullName).keys {
            _ = try await probe.run(["api"] + GHProbe.apiHeaders + ["-X", "DELETE", "repos/\(fullName)/environments/\(environment)"])
        }
        for secret in try await probe.secrets(fullName).keys {
            _ = try await probe.run(["secret", "delete", secret, "--repo=\(fullName)"])
        }
        for variable in try await probe.variables(fullName).keys {
            _ = try await probe.run(["variable", "delete", variable, "--repo=\(fullName)"])
        }
    }
}
