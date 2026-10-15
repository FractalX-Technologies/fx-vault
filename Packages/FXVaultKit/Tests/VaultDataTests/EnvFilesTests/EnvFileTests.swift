import Darwin
import EnvTools
import Foundation
import GitHubKit
import os
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// `.env` import and export (M5) on the real store, in temporary folders.
@Suite("EnvFileRepository")
struct EnvFileTests {
    /// Placeholder values only (no real credentials).
    static let sample = """
    # FXV fixture
    export DATABASE_URL=postgres://user-a:fixture-pass@db.example.invalid/app
    api-key=FXV_FIXTURE_TOKEN_ABCDEFGHIJ
    LOG_LEVEL=debug
    PEM="-----BEGIN FXV FIXTURE-----\\nAAAA\\n-----END FXV FIXTURE-----\\n"
    EMPTY=
    db_url=second
    """

    static let ownerOnlyMode: mode_t = S_IRUSR | S_IWUSR
    static let fileTypeMask: mode_t = S_IFMT

    struct Fixture {
        let harness: ConfigHarness
        let directory: ConfigTempDirectory
        let files: EnvFileRepository
        let repo: RepoModel
        let staging: EnvironmentID

        static func make(checker: any GitignoreChecker = StubGitignoreChecker()) async throws -> Fixture {
            let harness = try await ConfigHarness.make()
            let directory = try ConfigTempDirectory()
            let files = EnvFileRepository(
                session: harness.session,
                gitignoreChecker: checker,
                cloudSyncDetector: CloudSyncDetector(homeDirectory: directory.url, isUbiquitous: { _ in false }),
                clock: harness.clock
            )
            let repo = try harness.seedRepository()
            let staging = try harness.config.createEnvironment(in: repo.id, name: "staging")
            return Fixture(harness: harness, directory: directory, files: files, repo: repo, staging: staging)
        }

        func authorize() async throws -> EnvExportAuthorizationModel {
            try await ReauthGate(manager: harness.manager).authorizeEnvExport(
                with: .password(ConfigFixture.password),
                session: harness.session
            )
        }

        func items(_ scope: ConfigScope) throws -> [ConfigItemModel] {
            try harness.store.fetchItems(repositoryID: repo.id, scope: scope)
        }
    }

    // MARK: - Import

    @Test func importPreMarksSecretsAndNormalizesValues() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let preview = try fixture.files.parse(SecretBytes(utf8: Self.sample))
        defer { preview.wipe() }

        let selections = preview.defaultSelections
        #expect(selections.map(\.name) == ["DATABASE_URL", "API_KEY", "LOG_LEVEL", "PEM", "DB_URL"])
        #expect(selections.map(\.kind) == [.secret, .secret, .variable, .secret, .variable])
        #expect(preview.candidates.first { $0.key.originalKey == "EMPTY" }?.valueProblem == .emptyValue)

        let scope = ConfigScope.environment(fixture.staging)
        let result = try fixture.files.applyImport(preview, selections: selections, repositoryID: fixture.repo.id, scope: scope)
        #expect(result.added == ["DATABASE_URL", "API_KEY", "LOG_LEVEL", "PEM", "DB_URL"])
        #expect(result.strippedTrailingNewlines == ["PEM"])
        let items = try fixture.items(scope)
        let pem = try #require(items.first { $0.name == "PEM" })
        #expect(try fixture.harness.reveal(pem.id) == "-----BEGIN FXV FIXTURE-----\nAAAA\n-----END FXV FIXTURE-----")
        let url = try #require(items.first { $0.name == "DATABASE_URL" })
        #expect(try fixture.harness.reveal(url.id) == "postgres://user-a:fixture-pass@db.example.invalid/app")
        #expect(items.allSatisfy { $0.syncStatus == .added })
    }

    @Test func importConflictsSkipOrOverwriteAndReviveTombstones() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let harness = fixture.harness
        let scope = ConfigScope.repository
        let level = try harness.add(fixture.repo, "LOG_LEVEL", kind: .variable, value: "info", scope: scope)
        let key = try harness.add(fixture.repo, "API_KEY", value: ConfigFixture.valueA, scope: scope)
        try harness.markSynced(fixture.repo)
        try harness.config.deleteItem(key)

        let preview = try fixture.files.parse(SecretBytes(utf8: Self.sample))
        defer { preview.wipe() }
        let selections = preview.defaultSelections.filter { ["LOG_LEVEL", "API_KEY"].contains($0.name) }
        let conflicts = try fixture.files.conflicts(for: selections, in: preview, repositoryID: fixture.repo.id, scope: scope)
        #expect(conflicts.values.map(\.id) == [level])

        let skipped = try fixture.files.applyImport(preview, selections: selections, repositoryID: fixture.repo.id, scope: scope)
        #expect(skipped.added == ["API_KEY"])
        #expect(skipped.skipped.map(\.reason) == [.existingItem])
        #expect(try harness.reveal(level) == "info")
        // The deleted API_KEY was revived on its own row.
        #expect(try harness.state(key).isDeleted == false)
        #expect(try harness.reveal(key) == "FXV_FIXTURE_TOKEN_ABCDEFGHIJ")

        var overwrite = selections
        for index in overwrite.indices { overwrite[index].onConflict = .overwrite }
        let replaced = try fixture.files.applyImport(preview, selections: overwrite, repositoryID: fixture.repo.id, scope: scope)
        #expect(Set(replaced.overwritten) == ["LOG_LEVEL", "API_KEY"])
        #expect(try harness.reveal(level) == "debug")
        #expect(try harness.status(level) == .modified)
    }

    @Test func importSkipsInvalidAndDuplicateSelections() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let preview = try fixture.files.parse(SecretBytes(utf8: Self.sample))
        defer { preview.wipe() }
        let emptyIndex = try #require(preview.candidates.firstIndex { $0.key.originalKey == "EMPTY" })
        let selections = [
            EnvImportSelectionModel(candidateIndex: 2, name: "LOG_LEVEL", kind: .variable, onConflict: .skip),
            EnvImportSelectionModel(candidateIndex: 2, name: "log_level", kind: .variable, onConflict: .skip),
            EnvImportSelectionModel(candidateIndex: 2, name: "9LIVES", kind: .variable, onConflict: .skip),
            EnvImportSelectionModel(candidateIndex: emptyIndex, name: "EMPTY", kind: .variable, onConflict: .skip),
            EnvImportSelectionModel(candidateIndex: 99, name: "MISSING", kind: .variable, onConflict: .skip),
        ]
        let result = try fixture.files.applyImport(preview, selections: selections, repositoryID: fixture.repo.id, scope: .repository)
        #expect(result.added == ["LOG_LEVEL"])
        #expect(result.skipped.map(\.reason) == [
            .duplicateInImport,
            .invalidName(.invalidName(.leadingDigit)),
            .invalidValue(.emptyValue),
            .unknownCandidate,
        ])
    }

    @Test func importIsAllOrNothing() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let preview = try fixture.files.parse(SecretBytes(utf8: Self.sample))
        defer { preview.wipe() }
        fixture.harness.manager.lock()
        let error = envFileError { _ = try fixture.files.applyImport(preview, selections: preview.defaultSelections, repositoryID: fixture.repo.id, scope: .repository) }
        #expect(error == .config(.vault(.locked)))
        #expect(try fixture.items(.repository).isEmpty)
    }

    @Test func readFileParsesFromDisk() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let url = fixture.directory.file(".env")
        try Data(Self.sample.utf8).write(to: url)
        let preview = try fixture.files.readFile(at: url)
        defer { preview.wipe() }
        #expect(preview.candidates.count == 6)
        #expect(envFileError { _ = try fixture.files.readFile(at: fixture.directory.file("absent.env")) } == .fileUnreadable)
    }

    // MARK: - Export

    @Test func exportRoundTripsThroughAnOwnerOnlyFile() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let harness = fixture.harness
        let scope = ConfigScope.environment(fixture.staging)
        try harness.add(fixture.repo, "API_TOKEN", value: "tok'en \"quoted\" $HOME #x", scope: scope)
        try harness.add(fixture.repo, "API_TOKEN", kind: .variable, value: "collides", scope: scope)
        try harness.add(fixture.repo, "MULTI_LINE", kind: .variable, value: "line one\nline two", scope: scope)
        try harness.store.insertItem(ConfigItemRecord(
            repositoryID: fixture.repo.id,
            scope: scope,
            kind: .secret,
            name: "IMPORTED",
            valueCiphertext: nil,
            valueFingerprint: nil,
            syncedName: "IMPORTED",
            createdAt: harness.clock.now,
            updatedAt: harness.clock.now
        ))

        let preview = try fixture.files.exportPreview(repositoryID: fixture.repo.id, scope: scope)
        #expect(preview.exportedNames == ["API_TOKEN", "MULTI_LINE"])
        #expect(preview.valueMissingNames == ["IMPORTED"])
        #expect(preview.nameCollisions == ["API_TOKEN"])

        let url = fixture.directory.file("staging.env")
        let result = try fixture.files.export(
            repositoryID: fixture.repo.id,
            scope: scope,
            to: url,
            authorization: try await fixture.authorize(),
            headerComments: ["FX Vault export"]
        )
        #expect(result.preview == preview)
        var info = stat()
        #expect(stat(url.path, &info) == 0)
        #expect(info.st_mode & ~Self.fileTypeMask == Self.ownerOnlyMode)

        // Re-import the file into another environment: same names and values.
        let reimport = try fixture.files.readFile(at: url)
        defer { reimport.wipe() }
        let production = try harness.config.createEnvironment(in: fixture.repo.id, name: "production")
        let selections = reimport.defaultSelections.map {
            EnvImportSelectionModel(candidateIndex: $0.candidateIndex, name: $0.name, kind: .secret, onConflict: .skip)
        }
        try fixture.files.applyImport(reimport, selections: selections, repositoryID: fixture.repo.id, scope: .environment(production))
        let copies = try fixture.items(.environment(production))
        #expect(copies.map(\.name) == ["API_TOKEN", "MULTI_LINE"])
        #expect(try harness.reveal(copies[0].id) == "tok'en \"quoted\" $HOME #x")
        #expect(try harness.reveal(copies[1].id) == "line one\nline two")
    }

    @Test func exportNeedsAFreshSingleUseAuthorization() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        try fixture.harness.add(fixture.repo, "TOKEN", value: ConfigFixture.valueA)
        let authorization = try await fixture.authorize()
        #expect(authorization.isUsable)
        try fixture.files.export(repositoryID: fixture.repo.id, scope: .repository, to: fixture.directory.file("a.env"), authorization: authorization)
        #expect(authorization.isUsable == false)

        let reused = envFileError {
            _ = try fixture.files.export(repositoryID: fixture.repo.id, scope: .repository, to: fixture.directory.file("b.env"), authorization: authorization)
        }
        #expect(reused == .authorizationInvalid)

        // A lock in between invalidates a granted authorization.
        let stale = try await fixture.authorize()
        fixture.harness.manager.lock()
        try await fixture.harness.manager.unlock(password: ConfigFixture.password)
        let afterLock = envFileError {
            _ = try fixture.files.export(repositoryID: fixture.repo.id, scope: .repository, to: fixture.directory.file("c.env"), authorization: stale)
        }
        #expect(afterLock == .authorizationInvalid)

        // An authorization of another session is refused.
        let other = try await ConfigHarness.make()
        let foreign = try await ReauthGate(manager: other.manager).authorizeEnvExport(with: .password(ConfigFixture.password), session: other.session)
        let wrongSession = envFileError {
            _ = try fixture.files.export(repositoryID: fixture.repo.id, scope: .repository, to: fixture.directory.file("d.env"), authorization: foreign)
        }
        #expect(wrongSession == .authorizationInvalid)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.file("b.env").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.file("c.env").path))

        // Never through a symlink, and never over an existing file unless asked.
        let existing = envFileError {
            _ = try fixture.files.export(repositoryID: fixture.repo.id, scope: .repository, to: fixture.directory.file("a.env"), authorization: try freshAuthorization(fixture))
        }
        #expect(existing == .write(.destinationExists))
    }

    // MARK: - Destination checks

    @Test func destinationReportsGitExposureAndICloud() async throws {
        let checker = StubGitignoreChecker()
        let fixture = try await Fixture.make(checker: checker)
        defer { fixture.directory.remove() }
        checker.root.withLock { $0 = fixture.directory.url }
        let url = fixture.directory.file("out.env")

        let exposed = await fixture.files.inspectDestination(url)
        #expect(exposed.cloudSyncStatus == .notSynced)
        guard case .notIgnored(_, let relativePath, let line) = exposed.gitExposure else {
            Issue.record("Expected notIgnored, got \(String(describing: exposed.gitExposure))")
            return
        }
        #expect(relativePath == "out.env")
        #expect(line == "/out.env")

        checker.isTracked.withLock { $0 = true }
        #expect(await fixture.files.inspectDestination(url).gitExposure?.isExposed == true)

        checker.fails.withLock { $0 = true }
        #expect(await fixture.files.inspectDestination(url).gitCheckFailed)

        let iCloud = fixture.directory.url.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/out.env")
        #expect(await fixture.files.inspectDestination(iCloud).cloudSyncStatus == .iCloudDrive)
    }

    @Test func gitignoreEntryIsAppendedOnce() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.directory.remove() }
        let root = fixture.directory.url
        let gitignore = root.appendingPathComponent(".gitignore")

        #expect(try fixture.files.addGitignoreEntry(relativePath: "config/.env", repositoryRoot: root))
        #expect(try String(contentsOf: gitignore, encoding: .utf8) == "/config/.env\n")
        var info = stat()
        #expect(stat(gitignore.path, &info) == 0)
        #expect(info.st_mode & ~Self.fileTypeMask == EnvFileRepository.gitignoreFileMode)
        #expect(try fixture.files.addGitignoreEntry(relativePath: "config/.env", repositoryRoot: root) == false)

        try Data("node_modules\n".utf8).write(to: gitignore)
        #expect(chmod(gitignore.path, Self.ownerOnlyMode) == 0)
        #expect(try fixture.files.addGitignoreEntry(relativePath: "out.env", repositoryRoot: root))
        #expect(try String(contentsOf: gitignore, encoding: .utf8) == "node_modules\n/out.env\n")
        #expect(stat(gitignore.path, &info) == 0)
        #expect(info.st_mode & ~Self.fileTypeMask == Self.ownerOnlyMode)

        try FileManager.default.removeItem(at: gitignore)
        try FileManager.default.createSymbolicLink(at: gitignore, withDestinationURL: fixture.directory.file("elsewhere"))
        #expect(envFileError { _ = try fixture.files.addGitignoreEntry(relativePath: "out.env", repositoryRoot: root) } == .gitignoreNotRegularFile)
    }

    @Test func gitServiceCheckerUsesHardenedGit() async throws {
        let runner = FakeCommandRunner()
        let git = GitService(
            runner: runner,
            identity: GHFixtures.identity,
            shell: .empty,
            workingDirectory: GHFixtures.workingDirectory,
            clock: ManualClock()
        )
        let checker = GitServiceGitignoreChecker(git: git)
        let root = URL(fileURLWithPath: "/private/tmp/fxvault-tests/repo", isDirectory: true)
        runner.enqueue(.success(root.path + "\n"), matching: { $0.contains("rev-parse") })
        runner.enqueue(.failure(stderr: ""), matching: { $0.contains("check-ignore") })
        runner.enqueue(.success(), matching: { $0.contains("ls-files") })

        #expect(try await checker.repositoryRoot(containing: root.appendingPathComponent("config")) == root)
        #expect(try await checker.isIgnored(relativePath: "config/.env", inRepositoryAt: root) == false)
        #expect(try await checker.isTracked(relativePath: "config/.env", inRepositoryAt: root))
        #expect(runner.invocations.allSatisfy { $0.arguments.starts(with: ["-c", "core.fsmonitor="]) })
        #expect(runner.invocations.allSatisfy { $0.executablePath == "/usr/bin/git" })
    }

    // MARK: - Helpers

    private func freshAuthorization(_ fixture: Fixture) throws -> EnvExportAuthorizationModel {
        EnvExportAuthorizationModel(session: fixture.harness.session)
    }

    private func envFileError(_ body: () throws -> Void) -> EnvFileError? {
        do {
            try body()
            return nil
        } catch let error as EnvFileError {
            return error
        } catch {
            Issue.record("Expected an EnvFileError, got \(error)")
            return nil
        }
    }
}

/// A scripted ``GitignoreChecker``: one repository root, configurable answers, optional failure.
final class StubGitignoreChecker: GitignoreChecker {
    struct Failure: Error {}

    let root = OSAllocatedUnfairLock<URL?>(initialState: nil)
    let isIgnoredAnswer = OSAllocatedUnfairLock(initialState: false)
    let isTracked = OSAllocatedUnfairLock(initialState: false)
    let fails = OSAllocatedUnfairLock(initialState: false)

    func repositoryRoot(containing directory: URL) async throws -> URL? {
        if fails.withLock({ $0 }) { throw Failure() }
        return root.withLock { $0 }
    }

    func isIgnored(relativePath: String, inRepositoryAt root: URL) async throws -> Bool {
        isIgnoredAnswer.withLock { $0 }
    }

    func isTracked(relativePath: String, inRepositoryAt root: URL) async throws -> Bool {
        isTracked.withLock { $0 }
    }
}
