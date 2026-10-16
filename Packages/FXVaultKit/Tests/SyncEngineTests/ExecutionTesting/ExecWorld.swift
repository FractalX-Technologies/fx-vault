import Foundation
import FXVaultTestSupport
import GitHubKit
@testable import SyncEngine
import VaultCore

/// Builds one repository's local rows for execution tests. Synthetic names only
/// (`owner-a`, `user-a`, `FXV_*`-style items; tasks/lessons.md).
final class ExecScenario {
    static let account = "user-a"
    static let token = "fake-token-initial"

    var repository: RepoModel
    var environments: [EnvironmentModel] = []
    var items: [ConfigItemSnapshotModel] = []
    var values: [ConfigItemID: String] = [:]

    init(onGitHub: Bool = true, hasAdmin: Bool = true, hasPush: Bool = true, spec: RepoCreateSpecModel? = nil, visibility: RepoVisibility = .private) {
        repository = RepoModel(
            accountLogin: Self.account,
            githubID: onGitHub ? "R_simulated" : nil,
            ownerLogin: "owner-a",
            ownerType: .organization,
            name: "api",
            visibility: visibility,
            hasAdmin: hasAdmin,
            hasPush: hasPush,
            origin: onGitHub ? .imported : .created,
            importedAt: SteppingClock.start,
            createSpec: spec
        )
    }

    var snapshot: RepoSnapshotModel {
        RepoSnapshotModel(repository: repository, environments: environments, items: items)
    }

    /// A new (never synced) environment.
    @discardableResult
    func newEnvironment(_ name: String, policy: DeploymentBranchPolicyModel = .all) -> EnvironmentModel {
        let environment = EnvironmentModel(
            repositoryID: repository.id,
            name: name,
            branchPolicy: policy,
            createdAt: SteppingClock.start,
            updatedAt: SteppingClock.start
        )
        environments.append(environment)
        return environment
    }

    /// A synced environment, also created on `github`.
    @discardableResult
    func syncedEnvironment(
        _ name: String,
        github: GitHubSimulator,
        id: Int64 = 10,
        policy: DeploymentBranchPolicyModel = .all,
        foreignRulesJSON: String? = nil
    ) -> EnvironmentModel {
        let environmentID = EnvironmentID()
        let remotePatterns = policy.activePatterns.map { ($0.pattern, $0.type) }
        github.addEnvironment(name, id: id, policy: policy.kind, patterns: remotePatterns)
        let remote = github.environment(name)
        let synced: DeploymentBranchPolicyModel = switch policy {
        case .custom(let patterns):
            .custom(patterns.map { pattern in
                var pattern = pattern
                pattern.environmentID = environmentID
                pattern.githubPolicyID = remote?.patterns.first { $0.name == pattern.pattern }?.id
                return pattern
            })
        default:
            policy
        }
        let environment = EnvironmentModel(
            id: environmentID,
            repositoryID: repository.id,
            name: name,
            syncedName: name,
            branchPolicy: synced,
            syncedBranchPolicy: policy.kind,
            foreignRulesJSON: foreignRulesJSON,
            githubEnvID: id,
            createdAt: SteppingClock.start,
            updatedAt: SteppingClock.start
        )
        environments.append(environment)
        return environment
    }

    /// A never-synced item (pending add). `value` nil = value missing.
    @discardableResult
    func newItem(_ name: String, kind: ConfigKind, value: String?, in environment: EnvironmentModel? = nil) -> ConfigItemID {
        let id = ConfigItemID()
        items.append(ConfigItemSnapshotModel(
            id: id,
            scope: ConfigScope(environmentID: environment?.id),
            kind: kind,
            name: name,
            valueFingerprint: value.map { InMemorySyncVault.fingerprint($0, rowID: id) }
        ))
        values[id] = value
        return id
    }

    /// A synced item, also created on `github` (in the environment's synced name). `value` is the
    /// local value (nil = missing), `syncedValue` what was pushed.
    @discardableResult
    func syncedItem(
        _ name: String,
        kind: ConfigKind,
        value: String?,
        syncedValue: String,
        in environment: EnvironmentModel? = nil,
        github: GitHubSimulator,
        localName: String? = nil,
        isDeleted: Bool = false,
        forcePush: Bool = false
    ) -> ConfigItemID {
        let id = ConfigItemID()
        let remoteEnvironment = environment?.syncedName
        let updatedAt: Date = switch kind {
        case .secret: github.addSecret(name, environment: remoteEnvironment)
        case .variable: github.addVariable(name, value: syncedValue, environment: remoteEnvironment)
        }
        items.append(ConfigItemSnapshotModel(
            id: id,
            scope: ConfigScope(environmentID: environment?.id),
            kind: kind,
            name: localName ?? name,
            valueFingerprint: value.map { InMemorySyncVault.fingerprint($0, rowID: id) },
            isDeleted: isDeleted,
            syncedName: name,
            hasSyncedValue: true,
            syncedFingerprint: InMemorySyncVault.fingerprint(syncedValue, rowID: id),
            forcePush: forcePush,
            remoteUpdatedAt: updatedAt
        ))
        values[id] = value
        return id
    }
}

/// Everything an execution test needs: a simulated GitHub, the in-memory vault, the account's
/// scheduler (token pre-cached) and the sync services.
struct ExecWorld {
    let clock: any VaultClock
    let github: GitHubSimulator
    let vault: InMemorySyncVault
    let tokenCache: GHTokenCache
    let scheduler: GHCommandScheduler
    let registry: SyncSchedulerRegistry

    init(_ scenario: ExecScenario, github: GitHubSimulator, clock: any VaultClock = SteppingClock()) {
        self.clock = clock
        self.github = github
        vault = InMemorySyncVault(snapshots: [scenario.snapshot], values: scenario.values.compactMapValues { $0 }, clock: clock)
        tokenCache = GHTokenCache()
        tokenCache.store(SecretBytes(utf8: ExecScenario.token), for: ExecScenario.account)
        let service = GHCommandService(
            executableURL: URL(fileURLWithPath: "/nonexistent/fxvault-tests/gh"),
            identity: ProcessIdentityModel(home: "/Users/user-a", user: "user-a", temporaryDirectory: "/private/tmp/fxvault-tests"),
            shell: ShellEnvironmentModel(path: "/opt/homebrew/bin:/usr/bin:/bin"),
            workingDirectory: URL(fileURLWithPath: "/private/tmp/fxvault-tests/empty-cwd", isDirectory: true),
            runner: github
        )
        scheduler = GHCommandScheduler(
            accountLogin: ExecScenario.account,
            service: service,
            auth: GHAuthService(service: service, tokenCache: tokenCache),
            clock: clock
        )
        registry = SyncSchedulerRegistry([scheduler])
    }

    var repositoryID: RepoID {
        vault.snapshots[0].repository.id
    }

    var snapshot: RepoSnapshotModel {
        vault.snapshots[0]
    }

    func preflightService(writePolicy: WriteCollaboratorPolicy = .default, spaces: (any SyncSpaceCoordinating)? = nil) -> SyncPreflight {
        SyncPreflight(schedulers: registry, persistence: vault, values: vault, clock: clock, writePolicy: writePolicy, spaces: spaces)
    }

    func preflight(scopeStatus: [String: ScopeStatus] = [:]) async throws -> SyncPreflightModel {
        try await preflightService().run(vault.snapshots, scopeStatus: scopeStatus)
    }

    func executor(spaces: (any SyncSpaceCoordinating)? = nil) -> SyncExecutor {
        SyncExecutor(schedulers: registry, persistence: vault, values: vault, clock: clock, spaces: spaces)
    }

    func reconciler() -> SyncReconciler {
        SyncReconciler(schedulers: registry, persistence: vault, values: vault, clock: clock)
    }

    /// Preflight, plan and run.
    @discardableResult
    func sync(includeDeletions: Bool = true) async throws -> SyncResultModel {
        let preflight = try await preflight()
        return try await executor().run(SyncPlanner.plan(preflight, includeDeletions: includeDeletions))
    }

    /// Preflight, plan and run with shared spaces (v0.6.0).
    @discardableResult
    func sync(
        spaces: any SyncSpaceCoordinating,
        takeovers: Set<SpaceID> = [],
        spaceReason: String? = nil
    ) async throws -> SyncResultModel {
        let preflight = try await preflightService(spaces: spaces).run(vault.snapshots, spaceTakeovers: takeovers)
        return try await executor(spaces: spaces).run(SyncPlanner.plan(preflight, spaceReason: spaceReason))
    }

    /// The journal rows of `command`.
    func journal(_ command: SyncJournalCommand) -> [SyncJournalEntryModel] {
        vault.journal.filter { $0.command == command }
    }
}

extension SyncResultModel {
    /// The outcome of the change whose target is the item `name` (any scope) and kind `kind`.
    func outcome(of kind: ConfigChangeKind, _ name: String? = nil) -> SyncChangeOutcomeModel? {
        entries.first { entry in
            entry.change.kind == kind && (name == nil || ChangeTargetName.name(of: entry.change) == name)
        }?.outcome
    }
}

enum ChangeTargetName {
    static func name(of change: ConfigChangeModel) -> String? {
        switch change.operation {
        case .setItem(let set): set.name
        case .deleteItem(let delete): delete.name
        case .upsertEnvironment(let upsert): upsert.name
        case .renameEnvironment(let rename): rename.toName
        case .deleteEnvironment(let delete): delete.name
        case .reconcileBranchPatterns(let patterns): patterns.environmentName
        case .createRepository(let create): create.name
        }
    }
}
