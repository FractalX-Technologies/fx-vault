import EnvTools
import Foundation
import GitHubKit
import SyncEngine
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// Read-only checks against the real gh (`FXV_LIVE_E2E=1`, see ``LiveE2E``). Nothing is written
/// to GitHub: discovery from a Finder-like launch, the catalog, an import of a public repository
/// the account cannot administer, drift on it, a clone through the SSH alias and a `.env` export
/// next to a real `.gitignore`.
@Suite("Live E2E (read-only, opt-in)", .enabled(if: LiveE2E.isEnabled), .serialized, .timeLimit(.minutes(10)))
struct LiveE2EReadOnlyTests {
    // MARK: 1. Discovery

    @Test func discoveryWorksFromAFinderLaunch() async throws {
        let directory = try VaultTemporaryDirectory()
        defer { directory.remove() }
        let caches = directory.directory("caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let runner = ProcessRunner()
        let identity = ProcessIdentityModel.current(processEnvironment: LiveE2E.finderEnvironment)
        let workingDirectory = try EmptyWorkingDirectory.prepare(in: caches)
        let locator = GHLocator(runner: runner, identity: identity, workingDirectory: workingDirectory)

        // Without the shell probe (launchd's PATH only): the Homebrew fallback finds gh.
        let bare = try await locator.locate(overridePath: nil, shell: .empty)
        #expect(bare.version.isSupported)

        // With the login-shell probe (A2): a PATH is captured and leads to the same binary.
        let shell = try await ShellEnvironmentResolver(runner: runner, identity: identity, workingDirectory: workingDirectory).resolve()
        #expect(shell.path?.isEmpty == false)
        #expect(shell.path?.split(separator: ":").allSatisfy { $0.hasPrefix("/") } == true)
        let viaShell = try await locator.locate(overridePath: nil, shell: shell)
        #expect(viaShell.resolvedPath == bare.resolvedPath)
        #expect(viaShell.version == bare.version)
    }

    @Test func accountsScopesOrganizationsAndCatalogDecode() async throws {
        let world = try await E2EWorld.live()
        defer { world.remove() }
        let github = try #require(world.github)

        let accounts = try await github.accounts()
        let active = try #require(accounts.first { $0.status?.isActive == true })
        let status = try #require(active.status)
        #expect(status.state == .ok)
        #expect(status.scopes == .ok, "token scopes: \(String(describing: status.scopeList))")
        #expect(status.scopeList?.contains(ScopeChecker.repoScope) == true)
        // The stored row exists and is present.
        let stored = try #require(try AccountStore(database: world.database).fetch(login: status.login))
        #expect(stored.isPresent)

        let catalog = try await world.catalog.catalog(accountLogin: world.accountLogin)
        #expect(catalog.organizationsFailure == nil)
        let first = try #require(catalog.owners.first)
        #expect(OwnerLoginValidator.foldKey(first.login) == OwnerLoginValidator.foldKey(world.accountLogin))
        #expect(first.ownerType == .user)
        for owner in catalog.owners {
            #expect(owner.failure == nil, "owner listing failed: \(String(describing: owner.failure?.logCode))")
            #expect(!owner.isTruncated)
            for repository in owner.repositories {
                #expect(OwnerLoginValidator.foldKey(repository.ref.owner) == OwnerLoginValidator.foldKey(owner.login))
            }
        }
        #expect(catalog.owners.contains { !$0.repositories.isEmpty })

        // B10 pickers decode the real lists.
        let gitignores = try await world.creation.gitignoreTemplates(accountLogin: world.accountLogin)
        #expect(gitignores.contains("Swift"))
        let licenses = try await world.creation.licenseTemplates(accountLogin: world.accountLogin)
        #expect(licenses.contains { $0.key == "mit" })
        let owners = try await world.creation.owners(accountLogin: world.accountLogin)
        #expect(owners.first?.ownerType == .user)
    }

    // MARK: 3. Import without admin

    @Test func importOfAPublicRepositoryWithoutAdminMarksSecretsUnreadable() async throws {
        let world = try await E2EWorld.live()
        defer { world.remove() }
        let ref = try GHRepoRef(fullName: LiveE2E.readRepository)

        let looked = try await world.catalog.lookUpRepository(fullName: LiveE2E.readRepository, accountLogin: world.accountLogin)
        #expect(looked.ref == ref)
        #expect(!looked.hasAdmin)

        let result = try await world.catalog.importRepository(ref, accountLogin: world.accountLogin)
        #expect(result.repository.githubID != nil)
        #expect(result.repository.capability == .readOnly(.adminRequired) || !result.repository.hasAdmin)
        #expect(result.secretCount == 0)
        #expect(result.unreadable.contains { $0.target == .secrets(environment: nil) && $0.error == .writeAccessRequired })
        #expect(result.unreadable.contains { $0.target == .variables(environment: nil) && $0.error == .writeAccessRequired })

        let environments = try world.store.fetchEnvironments(repositoryID: result.repository.id)
        #expect(environments.count == result.environmentCount)
        for environment in environments {
            #expect(environment.githubEnvID != nil)
            #expect(environment.syncedName == environment.name)
            #expect(!environment.hasPendingRename)
            #expect(!environment.hasPendingPolicyChange)
        }
        #expect(try world.pendingCount() == 0)

        // Drift right after the import: nothing changed, unreadable scopes are not "deleted".
        let report = try await world.drift.refresh(result.repository.id)
        #expect(report.drifts.isEmpty, "unexpected drift: \(report.drifts.map(\.kind))")
        #expect(!report.unreadable.isEmpty)
    }

    // MARK: 6. Clone through the alias, `.env` export next to a `.gitignore`

    @Test func cloneThroughTheAliasUsesTheAliasRemote() async throws {
        let world = try await E2EWorld.live()
        defer { world.remove() }
        let github = try #require(world.github)
        let alias = LiveE2E.sshAlias

        let test = try await github.testSSHAlias(alias, for: world.accountLogin)
        #expect(test.isVerified, "ssh test: \(test)")

        let ref = try GHRepoRef(fullName: LiveE2E.cloneRepository)
        let folder = world.directory.directory("clones")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = try await world.git.clone(repo: ref, alias: alias, into: folder)
        #expect(destination.lastPathComponent == ref.name)
        let remote = try await LiveGit.run(["remote", "get-url", "origin"], in: destination)
        #expect(remote == GitService.cloneURL(alias: alias, repo: ref))
        // No leftover temporary clone directory.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
        // A second clone into the same folder is refused before git runs.
        await #expect(throws: GitError.destinationExists) {
            try await world.git.clone(repo: ref, alias: alias, into: folder)
        }
    }

    @Test func envExportDetectsGitignoreRulesInARealRepository() async throws {
        let world = try await E2EWorld.live()
        defer { world.remove() }
        // A staged (never synced) repository holds the values; nothing reaches GitHub.
        let staged = try await world.creation.stage(RepoCreationDraftModel(
            accountLogin: world.accountLogin,
            ownerLogin: world.accountLogin,
            ownerType: .user,
            name: "fx-vault-e2e-export-only",
            visibility: .private,
            spec: RepoCreateSpecModel(autoInit: false, gitignoreTemplate: nil, licenseTemplate: nil, cloneAfter: false),
            environments: [
                RepoCreationEnvironmentDraftModel(name: "production", items: [
                    RepoCreationItemDraftModel(kind: .variable, name: "FXV_E2E_REGION", value: SecretBytes(utf8: "me-central-1")),
                    RepoCreationItemDraftModel(kind: .secret, name: "FXV_E2E_API_TOKEN", value: SecretBytes(utf8: "fxv e2e token with spaces")),
                ]),
            ]
        ))
        let production = try #require(try world.environment("production", in: staged.repositoryID))

        let project = world.directory.directory("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await LiveGit.run(["init", "--quiet"], in: project)
        try Data(".env\n".utf8).write(to: project.appendingPathComponent(".gitignore"))

        let ignored = project.appendingPathComponent(".env")
        let exposed = project.appendingPathComponent(".env.production")
        let ignoredDestination = await world.envFiles.inspectDestination(ignored)
        guard case .ignored(_, let ignoredPath) = try #require(ignoredDestination.gitExposure) else {
            Issue.record("expected .ignored, got \(String(describing: ignoredDestination.gitExposure))")
            return
        }
        #expect(ignoredPath == ".env")
        let exposedDestination = await world.envFiles.inspectDestination(exposed)
        guard case .notIgnored(_, let exposedPath, let line) = try #require(exposedDestination.gitExposure) else {
            Issue.record("expected .notIgnored, got \(String(describing: exposedDestination.gitExposure))")
            return
        }
        #expect(exposedPath == ".env.production")
        #expect(line == "/.env.production")

        let authorization = try await ReauthGate(manager: world.manager)
            .authorizeEnvExport(with: .password(LiveE2E.password), session: world.session)
        let result = try world.envFiles.export(
            repositoryID: staged.repositoryID,
            scope: .environment(production.id),
            to: ignored,
            authorization: authorization
        )
        #expect(Set(result.preview.exportedNames) == ["FXV_E2E_REGION", "FXV_E2E_API_TOKEN"])
        let attributes = try FileManager.default.attributesOfItem(atPath: ignored.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
        let parsed = try DotEnvParser.parse(SecretBytes(try Data(contentsOf: ignored)))
        let values = Dictionary(parsed.entries.map { ($0.key, $0.value.utf8String() ?? "") }, uniquingKeysWith: { first, _ in first })
        #expect(values["FXV_E2E_REGION"] == "me-central-1")
        #expect(values["FXV_E2E_API_TOKEN"] == "fxv e2e token with spaces")
        // git agrees the export is ignored.
        #expect(try await LiveGit.run(["status", "--porcelain", "--ignored", "--", ".env"], in: project).hasPrefix("!!"))

        // The offered fix makes the exposed path ignored.
        #expect(try world.envFiles.addGitignoreEntry(relativePath: exposedPath, repositoryRoot: project))
        let fixed = await world.envFiles.inspectDestination(exposed)
        guard case .ignored = try #require(fixed.gitExposure) else {
            Issue.record("expected .ignored after the fix, got \(String(describing: fixed.gitExposure))")
            return
        }
    }
}

/// Plain `/usr/bin/git` for test setup and independent checks (not the app's hardened calls).
enum LiveGit {
    static func run(_ arguments: [String], in directory: URL) async throws -> String {
        let spec = CommandSpec(
            executableURL: URL(fileURLWithPath: GHConstants.gitPath),
            arguments: ["-C", directory.path] + arguments,
            environment: ProcessEnvironmentBuilder.git(
                identity: ProcessIdentityModel.current(processEnvironment: LiveE2E.finderEnvironment),
                shell: .empty
            ),
            workingDirectory: directory,
            timeout: Timeouts.ghDefault
        )
        let result = try await ProcessRunner().run(spec)
        defer { result.stdout.wipe() }
        try #require(result.exitCode == 0, "git \(arguments.first ?? "") failed: \(result.stderr)")
        return result.stdout.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
