import Foundation
import FXVaultTestSupport
import GitHubKit
import os
import SyncEngine
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// A `CommandRunning` for `git clone` that creates the temporary clone directory git would
/// create, then succeeds (no real git, no network). Records every argv.
final class CloningRunner: CommandRunning {
    private let calls = OSAllocatedUnfairLock<[[String]]>(initialState: [])

    var invocations: [[String]] {
        calls.withLock { $0 }
    }

    func run(_ spec: CommandSpec) async throws(CommandRunnerError) -> CommandResult {
        let arguments = spec.arguments
        calls.withLock { $0.append(arguments) }
        if arguments.contains("clone"),
           let index = arguments.firstIndex(of: "-C"),
           arguments.indices.contains(index + 1),
           let temporaryName = arguments.last {
            let folder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            try? FileManager.default.createDirectory(
                at: folder.appendingPathComponent(temporaryName, isDirectory: true),
                withIntermediateDirectories: false
            )
        }
        return CommandResult(exitCode: 0, stdout: SecretBytes(count: 0), stderr: "")
    }
}

/// ``RepoCreationRepository``: staging, a single Sync creating everything, cloning through the
/// mapped alias, the name check and the pickers.
@Suite("RepoCreation", .timeLimit(.minutes(1)))
struct RepoCreationTests {
    struct World {
        let harness: SyncHarness
        let creation: RepoCreationRepository
        let sync: SyncRepository
        let git: CloningRunner
        let folder: VaultTemporaryDirectory
    }

    /// A vault whose account maps an SSH alias, and a GitHub without `owner-a/api` yet.
    private func world(repositoryExists: Bool = false, alias: String? = SyncFixture.alias) async throws -> World {
        let github = GitHubSimulator(owner: SyncFixture.owner, name: SyncFixture.repoName, exists: repositoryExists)
        let harness = try await SyncHarness.make(github: github)
        try AccountStore(database: harness.database).save(AccountModel(
            login: SyncFixture.login,
            sshHostAlias: alias,
            lastSeenAt: harness.clock.now
        ))
        let runner = CloningRunner()
        let git = GitService(
            runner: runner,
            identity: GHFixtures.identity,
            shell: .empty,
            workingDirectory: GHFixtures.workingDirectory,
            clock: harness.clock
        )
        let creation = RepoCreationRepository(session: harness.session, schedulers: harness.schedulers, git: git, clock: harness.clock)
        let sync = SyncRepository(session: harness.session, schedulers: harness.schedulers, cloner: creation, clock: harness.clock)
        return World(harness: harness, creation: creation, sync: sync, git: runner, folder: try VaultTemporaryDirectory())
    }

    private func draft(
        name: String = SyncFixture.repoName,
        visibility: RepoVisibility = .public,
        cloneAfter: Bool = true,
        repositorySecret: String = "fixture-secret\n"
    ) -> RepoCreationDraftModel {
        RepoCreationDraftModel(
            accountLogin: SyncFixture.login,
            ownerLogin: SyncFixture.owner,
            ownerType: .organization,
            name: name,
            description: "Fixture repository",
            visibility: visibility,
            spec: RepoCreateSpecModel(autoInit: true, gitignoreTemplate: "Swift", licenseTemplate: "mit", cloneAfter: cloneAfter),
            items: [RepoCreationItemDraftModel(kind: .secret, name: "FXV_SENTRY_DSN", value: SecretBytes(utf8: repositorySecret))],
            environments: [
                RepoCreationEnvironmentDraftModel(
                    name: "production",
                    policy: .custom([BranchPatternDraftModel(pattern: "release/*", type: .branch)]),
                    items: [RepoCreationItemDraftModel(kind: .variable, name: "FXV_API_URL", value: SecretBytes(utf8: "https://api.example.invalid"))]
                ),
            ]
        )
    }

    // MARK: - One Sync creates everything (M4)

    @Test func oneSyncCreatesTheRepositoryItsEnvironmentAndItemsThenClones() async throws {
        let world = try await world()
        defer { world.folder.remove() }
        let staged = try await world.creation.stage(draft())
        #expect(staged.strippedTrailingNewlines == ["FXV_SENTRY_DSN"])
        let repository = try world.harness.repository()
        #expect(repository.id == staged.repositoryID)
        #expect(repository.githubID == nil)
        #expect(repository.origin == .created)
        #expect(repository.createSpec?.cloneAfter == true)

        let review = try await world.sync.preflight()
        #expect(review.summary.repositories.first?.newRepository?.licenseTemplate == "mit")
        let handle = try await world.sync.startRun(review, includeDeletions: true, cloneFolder: world.folder.url)
        let outcome = await handle.outcome()

        #expect(outcome.result.stopReason == nil)
        #expect(outcome.result.failed.isEmpty)
        let github = world.harness.github
        #expect(github.repositoryExists)
        let create = try #require(github.calls.first { $0.starts(with: ["repo", "create"]) })
        #expect(create.contains("--public"))
        #expect(create.contains("--add-readme"))
        #expect(create.contains("--gitignore=Swift"))
        #expect(create.contains("--license=mit"))
        #expect(!create.contains("--clone"))
        let production = try #require(github.environment("production"))
        #expect(production.policy == .custom)
        #expect(production.patterns.map(\.name) == ["release/*"])
        #expect(github.secret("FXV_SENTRY_DSN")?.value == "fixture-secret")
        #expect(github.variable("FXV_API_URL", environment: "production")?.value == "https://api.example.invalid")

        let created = try world.harness.repository()
        #expect(created.githubID == "R_simulated")
        #expect(try world.harness.pendingCount() == 0)

        let clone = try #require(outcome.clones.first)
        guard case .cloned(let destination) = clone.state else {
            Issue.record("Expected a clone, got \(clone.state)")
            return
        }
        #expect(destination.lastPathComponent == SyncFixture.repoName)
        #expect(destination.deletingLastPathComponent().lastPathComponent == world.folder.url.lastPathComponent)
        #expect(created.clonePath == destination.path)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        let gitCall = try #require(world.git.invocations.first)
        #expect(gitCall.contains("git@\(SyncFixture.alias):owner-a/api.git"))
    }

    @Test func cloneIsNotAttemptedWithoutAFolder() async throws {
        let world = try await world()
        try await world.creation.stage(draft())
        let review = try await world.sync.preflight()
        let outcome = await (try await world.sync.startRun(review, includeDeletions: true)).outcome()
        #expect(outcome.clones.map(\.state) == [.notAttempted])
        #expect(world.git.invocations.isEmpty)
    }

    // MARK: - Staging rules

    @Test func stagingValidatesAndIsAllOrNothing() async throws {
        let world = try await world()
        await #expect(throws: RepoCreationError.validation(.invalidName(.dotName))) {
            try await world.creation.stage(draft(name: ".."))
        }
        await #expect(throws: RepoCreationError.validation(.emptyValue)) {
            try await world.creation.stage(draft(repositorySecret: "\n"))
        }
        var invalidItem = draft()
        invalidItem.items.append(RepoCreationItemDraftModel(kind: .secret, name: "GITHUB_TOKEN", value: SecretBytes(utf8: "x")))
        await #expect(throws: RepoCreationError.self) {
            try await world.creation.stage(invalidItem)
        }
        // Nothing was written by the refused drafts.
        #expect(try RepoStore(database: world.harness.database).fetchAll().isEmpty)

        let staged = try await world.creation.stage(draft())
        await #expect(throws: RepoCreationError.repositoryExists(staged.repositoryID)) {
            try await world.creation.stage(draft())
        }
    }

    @Test func aStagedRepositoryCanBeDiscardedUntilItExists() async throws {
        let world = try await world()
        let staged = try await world.creation.stage(draft(cloneAfter: false))
        try await world.creation.discardStaged(staged.repositoryID)
        #expect(try RepoStore(database: world.harness.database).fetch(id: staged.repositoryID) == nil)
        await #expect(throws: RepoCreationError.repositoryNotFound) {
            try await world.creation.discardStaged(staged.repositoryID)
        }

        let again = try await world.creation.stage(draft(cloneAfter: false))
        _ = try await world.harness.runSync()
        await #expect(throws: RepoCreationError.alreadyOnGitHub) {
            try await world.creation.discardStaged(again.repositoryID)
        }
    }

    // MARK: - Name check and pickers

    @Test func availabilityIsCheckedWithB2() async throws {
        let world = try await world(repositoryExists: true)
        #expect(await world.creation.checkAvailability(owner: "owner-a", name: "api", accountLogin: SyncFixture.login) == .taken)
        #expect(await world.creation.checkAvailability(owner: "owner-a", name: "fresh", accountLogin: SyncFixture.login) == .probablyAvailable)
        #expect(await world.creation.checkAvailability(owner: "owner-a", name: "..", accountLogin: SyncFixture.login) == .invalid(.invalidName(.dotName)))
        world.harness.github.enqueue(.failure(stderr: GHFixtures.saml), matching: GHMatch.repoView)
        let failed = await world.creation.checkAvailability(owner: "owner-a", name: "other", accountLogin: SyncFixture.login)
        guard case .unknown(.samlRequired) = failed else {
            Issue.record("A failed check is unknown, got \(failed)")
            return
        }
    }

    @Test func ownersAndTemplates() async throws {
        let world = try await world()
        world.harness.github.enqueue(.success("org-a\nowner-a\n"), matching: GHMatch.prefix(["org", "list"]))
        let owners = try await world.creation.owners(accountLogin: SyncFixture.login)
        #expect(owners == [
            RepoOwnerChoiceModel(login: SyncFixture.login, ownerType: .user),
            RepoOwnerChoiceModel(login: "org-a", ownerType: .organization),
            RepoOwnerChoiceModel(login: "owner-a", ownerType: .organization),
        ])

        world.harness.github.enqueue(.success("Swift\nGo\n"), matching: GHMatch.prefix(["repo", "gitignore", "list"]))
        #expect(try await world.creation.gitignoreTemplates(accountLogin: SyncFixture.login) == ["Swift", "Go"])
        #expect(try await world.creation.gitignoreTemplates(accountLogin: "USER-A") == ["Swift", "Go"])
        world.harness.github.enqueue(.success("mit\tMIT\tMIT License\n"), matching: GHMatch.prefix(["repo", "license", "list"]))
        #expect(try await world.creation.licenseTemplates(accountLogin: SyncFixture.login).map(\.key) == ["mit"])
        let templateCalls = world.harness.github.calls.filter { $0.starts(with: ["repo", "gitignore"]) }
        #expect(templateCalls.count == 1)
    }

    // MARK: - Clone button

    @Test func cloneNeedsAMappedAliasAndAnExistingRepository() async throws {
        let world = try await world(repositoryExists: true, alias: nil)
        defer { world.folder.remove() }
        let staged = try await world.creation.stage(draft(name: "staged-only", cloneAfter: false))
        await #expect(throws: RepoCreationError.notOnGitHub) {
            _ = try await world.creation.clone(staged.repositoryID, into: world.folder.url)
        }
        let imported = try await world.harness.importRepository()
        await #expect(throws: RepoCreationError.sshAliasNotMapped) {
            _ = try await world.creation.clone(imported.id, into: world.folder.url)
        }
        await #expect(throws: RepoCreationError.repositoryNotFound) {
            _ = try await world.creation.clone(RepoID(), into: world.folder.url)
        }
        #expect(world.git.invocations.isEmpty)
    }

    @Test func cloneButtonClonesAnImportedRepository() async throws {
        let world = try await world(repositoryExists: true)
        defer { world.folder.remove() }
        let imported = try await world.harness.importRepository()
        let destination = try await world.creation.clone(imported.id, into: world.folder.url)
        #expect(destination.lastPathComponent == SyncFixture.repoName)
        #expect(try world.harness.repository().clonePath == destination.path)
        await #expect(throws: RepoCreationError.git(.destinationExists)) {
            _ = try await world.creation.clone(imported.id, into: world.folder.url)
        }
    }

    @Test func cloneWithoutGitIsUnavailable() async throws {
        let world = try await world(repositoryExists: true)
        let creation = RepoCreationRepository(session: world.harness.session, schedulers: world.harness.schedulers, git: nil)
        await #expect(throws: RepoCreationError.gitUnavailable) {
            _ = try await creation.clone(RepoID(), into: world.folder.url)
        }
    }
}
