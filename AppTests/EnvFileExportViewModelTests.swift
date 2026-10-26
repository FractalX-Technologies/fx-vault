import EnvTools
import Foundation
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// `EnvExportScreen` (§5.13, §8 D4–D6, M5): ReauthGate first, warnings, iCloud confirmation,
/// the 0600 write, git checks and the `.gitignore` offer.
@MainActor
@Suite("Env export")
struct EnvFileExportViewModelTests {
    @MainActor
    struct Fixture {
        let harness: TestHarness
        let recorder = ActionRecorder()
        let repositoryID: RepoID

        init(
            signed: Bool = true,
            items: [RepoCreationItemDraftModel] = [
                TestFixtures.item(.secret, "API_TOKEN", EnvFileFixtures.secretValue),
                TestFixtures.item(.variable, "BASE_URL", EnvFileFixtures.variableValue),
            ]
        ) async throws {
            harness = try await TestHarness(vault: .unlocked, signed: signed)
            repositoryID = try await harness.stageRepository(items: items)
        }

        init(harness: TestHarness, repositoryID: RepoID) {
            self.harness = harness
            self.repositoryID = repositoryID
        }

        /// A view model whose preview has loaded.
        func viewModel(
            git: FakeGitignoreChecker.Answer = .outsideRepository,
            touchIDStatus: BiometricUnlockStatus? = nil
        ) async -> EnvExportViewModel {
            let model = EnvExportViewModel(
                context: EnvExportContext(repositoryID: repositoryID, scope: .repository),
                dependencies: harness.dependencies(recorder: recorder),
                envFiles: EnvFileFixtures.repository(harness, git: git),
                touchIDStatus: touchIDStatus
            )
            #expect(await TestFixtures.eventually { model.preview != nil })
            return model
        }

        /// A view model past ReauthGate (master password).
        func authenticated(git: FakeGitignoreChecker.Answer = .outsideRepository) async -> EnvExportViewModel {
            let model = await viewModel(git: git)
            model.password = testPassword
            await model.authenticateWithPassword()
            #expect(model.step == .review)
            return model
        }

        func destination(_ folder: String = "out", fileName: String = ".env") throws -> URL {
            let directory = try EnvFileFixtures.makeDirectory(harness.sandbox.appending(path: folder, directoryHint: .isDirectory))
            return directory.appending(path: fileName, directoryHint: .notDirectory)
        }
    }

    static func outcome(_ model: EnvExportViewModel) throws -> EnvExportOutcomeModel {
        guard case .done(let outcome) = model.step else {
            throw ExpectedStepMissing()
        }
        return outcome
    }

    struct ExpectedStepMissing: Error {}

    static func fileMode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    // MARK: - ReauthGate first

    @Test func startsWithReauthenticationAndWritesNothingBeforeIt() async throws {
        let fixture = try await Fixture()
        let model = await fixture.viewModel()
        let url = try fixture.destination()

        #expect(model.step == .authenticate)
        #expect(model.hasSomethingToExport)
        #expect(model.exportedCount == 2)
        #expect(model.repositoryName == "\(TestFixtures.owner)/\(TestFixtures.repoName)")
        #expect(model.scopeTitle == "Repository")
        #expect(model.placeTitle == TestFixtures.repoName, "the bare name, as the boards and the Delete sheet")
        #expect(model.showsTouchIDButton)
        #expect(model.defaultAction == .touchID)
        model.password = "typed"
        #expect(model.defaultAction == .password)

        await model.chooseDestination(url)

        #expect(model.step == .authenticate)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func anEnvironmentIsTitledWithItsRepository() async throws {
        let harness = try await TestHarness(vault: .unlocked, signed: true)
        let id = try await harness.stageRepository(environments: [RepoCreationEnvironmentDraftModel(name: "staging")])
        let scopes = try harness.data.config.scopes(repositoryID: id)
        let staging = try #require(scopes.first { $0.environment?.name == "staging" }).scope
        let model = EnvExportViewModel(
            context: EnvExportContext(repositoryID: id, scope: staging),
            dependencies: harness.dependencies(recorder: ActionRecorder()),
            envFiles: EnvFileFixtures.repository(harness, git: .outsideRepository),
            touchIDStatus: nil
        )
        #expect(await TestFixtures.eventually { model.placeTitle == "\(TestFixtures.repoName) › staging" })
    }

    @Test func wrongPasswordStaysOnAuthenticationAndClearsTheField() async throws {
        let fixture = try await Fixture()
        let model = await fixture.viewModel()
        model.password = otherTestPassword

        await model.authenticateWithPassword()

        #expect(model.step == .authenticate)
        #expect(model.password.isEmpty)
        #expect(model.authError?.title == "Incorrect password")
    }

    @Test func passwordThenWriteCreatesAnOwnerOnlyFile() async throws {
        let fixture = try await Fixture()
        let model = await fixture.authenticated()
        #expect(model.password.isEmpty)
        #expect(model.defaultAction == .chooseLocation)
        let url = try fixture.destination()

        await model.chooseDestination(url)

        let outcome = try Self.outcome(model)
        #expect(outcome.result.preview.exportedNames == ["API_TOKEN", "BASE_URL"])
        #expect(outcome.destination.gitExposure == .outsideRepository)
        #expect(model.gitignoreState == .notApplicable)
        #expect(model.defaultAction == .done)
        #expect(try Self.fileMode(url) == EnvFileFixtures.ownerOnlyMode)
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.hasPrefix("# Exported by FX Vault"))
        #expect(contents.contains("API_TOKEN=\(EnvFileFixtures.secretValue)"))
        #expect(!String(describing: model.step).contains(EnvFileFixtures.secretValue))
        #expect(!model.unverifiedShareNames.contains(EnvFileFixtures.secretValue))
    }

    @Test func aFailedWriteConsumesTheAuthorization() async throws {
        let fixture = try await Fixture()
        let model = await fixture.authenticated()
        let target = try fixture.destination(fileName: "target.txt")
        try Data("untouched".utf8).write(to: target)
        let link = try fixture.destination(fileName: ".env")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        await model.chooseDestination(link)

        #expect(model.step == .authenticate)
        #expect(model.alert?.title == "The .env file was not written")
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    }

    // MARK: - Touch ID

    @Test func touchIDGoesThroughReauthGateWithTheExportPrompt() async throws {
        let fixture = try await Fixture()
        try await fixture.harness.enableTouchID()
        let status = try fixture.harness.vaultManager.biometricUnlockStatus()
        let model = await fixture.viewModel(touchIDStatus: status)
        let loads = fixture.harness.biometrics.loadCount
        #expect(model.showsTouchIDButton)

        await model.authenticateWithTouchID()

        #expect(fixture.harness.biometrics.loadCount == loads + 1)
        #expect(fixture.harness.biometrics.lastPrompt == FeatureDependencies.reauthPrompt(for: .export))
        #expect(model.step == .review)
    }

    @Test func touchIDCancelIsSilentAndFallbackFocusesThePassword() async throws {
        let fixture = try await Fixture()
        try await fixture.harness.enableTouchID()
        let model = await fixture.viewModel(touchIDStatus: .available)

        fixture.harness.biometrics.failNextLoad(with: .cancelled)
        await model.authenticateWithTouchID()
        #expect(model.step == .authenticate)
        #expect(model.authError == nil)
        #expect(model.passwordFocusRequest == 0)

        fixture.harness.biometrics.failNextLoad(with: .passwordFallbackRequested)
        await model.authenticateWithTouchID()
        #expect(model.step == .authenticate)
        #expect(model.authError == nil)
        #expect(model.passwordFocusRequest == 1)
        #expect(model.showsTouchIDButton)
    }

    @Test func unavailableTouchIDHidesTheButtonAfterTheFirstAnswer() async throws {
        let fixture = try await Fixture(signed: false)
        let model = await fixture.viewModel(touchIDStatus: nil)
        #expect(model.showsTouchIDButton)

        await model.authenticateWithTouchID()

        #expect(model.step == .authenticate)
        #expect(!model.showsTouchIDButton)
        #expect(model.passwordFocusRequest == 1)
        #expect(model.defaultAction == .password)
    }

    @Test func knownUnavailableTouchIDIsNeverOffered() async throws {
        let fixture = try await Fixture()
        let model = await fixture.viewModel(touchIDStatus: .passwordRequired(.restart))
        #expect(!model.showsTouchIDButton)
        #expect(model.touchIDNotice != nil)
        #expect(!model.canAuthenticateWithTouchID)
        #expect(model.defaultAction == .password)
    }

    // MARK: - Warnings

    @Test func valueMissingSecretsAreListedAsSkippedAndNeverWritten() async throws {
        let harness = try await TestHarness(vault: .unlocked, ghStatus: nil)
        let repositoryID = try await EnvFileFixtures.importRepositoryWithMissingSecret(harness)
        let fixture = Fixture(harness: harness, repositoryID: repositoryID)
        let model = await fixture.authenticated()

        #expect(model.valueMissingNames == ["MISSING_SECRET"])
        #expect(model.exportedCount == 1)
        let url = try fixture.destination()
        await model.chooseDestination(url)

        let outcome = try Self.outcome(model)
        #expect(outcome.result.preview.valueMissingNames == ["MISSING_SECRET"])
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("PUBLIC_URL="))
        #expect(!contents.contains("MISSING_SECRET"))
    }

    @Test func emptyScopeCannotStartTheExport() async throws {
        let fixture = try await Fixture(items: [])
        let model = await fixture.viewModel()
        model.password = testPassword
        #expect(!model.hasSomethingToExport)
        #expect(!model.canAuthenticateWithPassword)
        #expect(!model.canAuthenticateWithTouchID)

        await model.authenticateWithPassword()

        #expect(model.step == .authenticate)
        #expect(model.password == testPassword)
    }

    @Test func unverifiedShareNamesListOnlyExportedShareItems() {
        let repositoryID = RepoID()
        let now = Date()
        func item(_ kind: ConfigKind, _ name: String, provenance: ConfigProvenance, value: ConfigValueState = .present) -> ConfigItemModel {
            ConfigItemModel(
                repositoryID: repositoryID,
                scope: .repository,
                kind: kind,
                name: name,
                valueState: value,
                provenance: provenance,
                syncStatus: .unverifiedShare,
                createdAt: now,
                updatedAt: now
            )
        }
        let items = [
            item(.secret, "SHARED_TOKEN", provenance: .share),
            item(.secret, "LOCAL_TOKEN", provenance: .local),
            item(.variable, "SHARED_TOKEN", provenance: .share),
            item(.secret, "SHARED_MISSING", provenance: .share, value: .missing),
            item(.variable, "SHARED_URL", provenance: .share),
        ]
        let preview = EnvExportPreviewModel(
            exportedNames: ["LOCAL_TOKEN", "SHARED_TOKEN", "SHARED_URL"],
            valueMissingNames: ["SHARED_MISSING"],
            nameCollisions: ["SHARED_TOKEN"]
        )

        #expect(EnvExportViewModel.unverifiedShareNames(in: items, preview: preview) == ["SHARED_TOKEN", "SHARED_URL"])
    }

    // MARK: - iCloud

    @Test func iCloudFolderAsksFirstAndDefaultsToChoosingAgain() async throws {
        let fixture = try await Fixture()
        let model = await fixture.authenticated()
        let home = EnvFileFixtures.home(of: fixture.harness)
        let cloud = try EnvFileFixtures.makeDirectory(home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory))
        let cloudURL = cloud.appending(path: ".env")

        await model.chooseDestination(cloudURL)

        guard case .confirmCloudSync(let choice) = model.step else {
            Issue.record("Expected the iCloud confirmation")
            return
        }
        #expect(choice.destination.cloudSyncStatus == .iCloudDrive)
        #expect(model.defaultAction == .chooseAnotherLocation)
        #expect(!FileManager.default.fileExists(atPath: cloudURL.path(percentEncoded: false)))

        model.chooseAnotherLocation()
        #expect(model.step == .review)
        let safeURL = try fixture.destination()
        await model.chooseDestination(safeURL)
        _ = try Self.outcome(model)
        #expect(FileManager.default.fileExists(atPath: safeURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: cloudURL.path(percentEncoded: false)))
    }

    @Test func exportAnywayWritesIntoTheSyncedFolder() async throws {
        let fixture = try await Fixture()
        let model = await fixture.authenticated()
        let cloud = try EnvFileFixtures.makeDirectory(
            EnvFileFixtures.home(of: fixture.harness).appending(path: "Library/Mobile Documents", directoryHint: .isDirectory)
        )
        let url = cloud.appending(path: ".env")

        await model.chooseDestination(url)
        await model.confirmCloudSyncExport()

        let outcome = try Self.outcome(model)
        #expect(outcome.destination.cloudSyncStatus == .iCloudDrive)
        #expect(try Self.fileMode(url) == EnvFileFixtures.ownerOnlyMode)
    }

    // MARK: - git checks after the write

    @Test func trackedFileShowsTheAlreadyCommittedWarning() async throws {
        let fixture = try await Fixture()
        let root = try EnvFileFixtures.makeDirectory(fixture.harness.sandbox.appending(path: "repo", directoryHint: .isDirectory))
        let model = await fixture.authenticated(git: .repository(root: root, isTracked: true, isIgnored: false))

        await model.chooseDestination(root.appending(path: ".env"))

        let outcome = try Self.outcome(model)
        guard case .tracked(_, let relativePath) = outcome.destination.gitExposure else {
            Issue.record("Expected a tracked file")
            return
        }
        #expect(relativePath == ".env")
        #expect(model.gitignoreState == .notApplicable)
        #expect(model.defaultAction == .done)
    }

    @Test func notIgnoredFileOffersTheGitignoreEntry() async throws {
        let fixture = try await Fixture()
        let root = try EnvFileFixtures.makeDirectory(fixture.harness.sandbox.appending(path: "repo", directoryHint: .isDirectory))
        let model = await fixture.authenticated(git: .repository(root: root, isTracked: false, isIgnored: false))

        await model.chooseDestination(root.appending(path: ".env"))

        #expect(model.gitignoreState == .offered(line: "/.env"))
        #expect(model.defaultAction == .addToGitignore)

        model.addGitignoreEntry()

        #expect(model.gitignoreState == .added(line: "/.env"))
        #expect(model.defaultAction == .done)
        let gitignore = try String(contentsOf: root.appending(path: ".gitignore"), encoding: .utf8)
        #expect(gitignore == "/.env\n")
    }

    @Test func existingEntryIsReportedAsAlreadyPresent() async throws {
        let fixture = try await Fixture()
        let root = try EnvFileFixtures.makeDirectory(fixture.harness.sandbox.appending(path: "repo", directoryHint: .isDirectory))
        try Data("/.env\n".utf8).write(to: root.appending(path: ".gitignore"))
        let model = await fixture.authenticated(git: .repository(root: root, isTracked: false, isIgnored: false))

        await model.chooseDestination(root.appending(path: ".env"))
        model.addGitignoreEntry()

        #expect(model.gitignoreState == .alreadyPresent)
    }

    @Test func ignoredFileNeedsNoOffer() async throws {
        let fixture = try await Fixture()
        let root = try EnvFileFixtures.makeDirectory(fixture.harness.sandbox.appending(path: "repo", directoryHint: .isDirectory))
        let model = await fixture.authenticated(git: .repository(root: root, isTracked: false, isIgnored: true))

        await model.chooseDestination(root.appending(path: ".env"))

        let outcome = try Self.outcome(model)
        guard case .ignored = outcome.destination.gitExposure else {
            Issue.record("Expected an ignored file")
            return
        }
        #expect(model.gitignoreState == .notApplicable)
    }

    @Test func aFailedGitCheckIsNeverReportedAsSafe() async throws {
        let fixture = try await Fixture()
        let model = await fixture.authenticated(git: .failure)

        await model.chooseDestination(try fixture.destination())

        let outcome = try Self.outcome(model)
        #expect(outcome.destination.gitCheckFailed)
        #expect(model.gitignoreState == .notApplicable)
    }

    @Test func replacingAFileTheSavePanelConfirmedIsAllowed() async throws {
        let fixture = try await Fixture()
        let model = await fixture.authenticated()
        let url = try fixture.destination()
        try Data("OLD=1\n".utf8).write(to: url)

        await model.chooseDestination(url)

        _ = try Self.outcome(model)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("API_TOKEN="))
        #expect(try Self.fileMode(url) == EnvFileFixtures.ownerOnlyMode)
    }

    // MARK: - Lock

    @Test func lockDropsTheAuthorization() async throws {
        let fixture = try await Fixture()
        let model = await fixture.authenticated()
        model.password = "typed"

        fixture.harness.app.lock(trigger: .manual)

        #expect(model.step == .authenticate)
        #expect(model.password.isEmpty)
        let url = try fixture.destination()
        await model.chooseDestination(url)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }
}
