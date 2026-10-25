import Foundation
import SharingKit
import Testing
import VaultCore
import VaultData
@testable import FXVault

/// Opening a project share (v0.9.0, P3, P7): passphrase files, the repository list, files that
/// cannot be opened here, the import, its holds and the Overview it opens.
@MainActor
@Suite("Project share import", .serialized)
struct ProjectShareImportViewModelTests {
    private func importer(_ world: ProjectShareWorld, file: URL) -> ShareImportViewModel {
        ShareImportViewModel(context: ShareImportContext(fileURL: file), dependencies: world.receiverDependencies())
    }

    @Test func aPassphraseBundleOpensItsRepositoryListAndImports() async throws {
        let world = try await ProjectShareWorld()
        let exported = try await world.exportBundle()
        let model = importer(world, file: try world.deliver(exported.url))
        await model.start()
        #expect(model.step == .passphrase)
        model.passphrase = exported.passphrase
        await model.open()

        #expect(model.step == .bundlePreview, "\(String(describing: model.passphraseError))")
        let editor = try #require(model.bundleEditor)
        #expect(editor.sender.displayName == ProjectShareWorld.identity.displayName)
        let row = try #require(editor.repositoryRows.first)
        #expect(row.mark == .inVault)
        #expect(row.destinationCount == 1)
        let repository = try #require(editor.selectedRepository)
        #expect(editor.githubEditor(for: repository) != nil)
        #expect(repository.destinations.first?.localDestinationID == nil)

        #expect(model.canApplyBundle)
        await model.applyBundle()
        #expect(model.step == .bundleDone, "\(String(describing: model.alert))")
        let result = try #require(model.bundleResult)
        #expect(result.destinationsCreated.count == 1)
        #expect(result.heldCount > 0)
        // The repository opens at the environment of the file's first stage.
        let opened = try #require(world.openedScopes.first)
        #expect(opened.0 == world.receiverRepositoryID)
        let receiverRepositoryID = try #require(world.receiverRepositoryID)
        let staging = try #require(try world.receiver.data.config.scopes(repositoryID: receiverRepositoryID).first {
            $0.environment?.name == "staging"
        })
        #expect(opened.1 == staging.scope)
    }

    @Test func choicesInARepositoryPreviewReachTheBundlePlan() async throws {
        let world = try await ProjectShareWorld()
        let exported = try await world.exportBundle()
        let model = importer(world, file: try world.deliver(exported.url))
        await model.start()
        model.passphrase = exported.passphrase
        await model.open()
        let editor = try #require(model.bundleEditor)
        let repository = try #require(editor.selectedRepository)
        let github = try #require(editor.githubEditor(for: repository))
        let differing = try #require(github.plan.allItems.first { $0.chip == .differs })
        #expect(differing.action == .keepMine)
        github.select(.overwrite, for: differing)
        let inBundle = editor.plan.repositories.first?.githubPlan?.allItems.first { $0.id == differing.id }
        #expect(inBundle?.action == .overwrite)
        #expect(editor.choices.count == 1)
    }

    @Test func anExpiredFileIsRefusedEvenWithTheRightPassphrase() async throws {
        let world = try await ProjectShareWorld()
        let exported = try await world.exportBundle(expiry: .oneDay)
        world.receiver.clock.advance(by: .seconds(2 * Timeouts.secondsPerDay))
        let model = importer(world, file: try world.deliver(exported.url))
        await model.start()
        model.passphrase = exported.passphrase
        await model.open()
        #expect(model.step == .failed)
        #expect(model.failure == SharingError.share(.expired).presentation)
        #expect(model.passphrase.isEmpty)
    }

    @Test func aRepositoryTheReceiverDoesNotHaveIsSkipped() async throws {
        let world = try await ProjectShareWorld(receiverHasRepository: false)
        let exported = try await world.exportBundle()
        let model = importer(world, file: try world.deliver(exported.url))
        await model.start()
        model.passphrase = exported.passphrase
        await model.open()
        let editor = try #require(model.bundleEditor)
        let row = try #require(editor.repositoryRows.first)
        #expect(row.mark == .skipped)
        #expect(!editor.canApply)
    }

    @Test(arguments: [
        (ShareBundleRepositoryStatus.inVault, ProjectShareImportEditor.RepositoryRowModel.Mark.inVault),
        (.willImportFromGitHub(accountLogin: "user-a"), .willImport),
        (.willImportFromGitHub(accountLogin: nil), .willImport),
        (.noAccess(.notVisible), .skipped),
        (.noAccess(.unreachable), .skipped),
        (.blocked(.repositoryIDMismatch), .skipped),
    ])
    func repositoryMarks(_ status: ShareBundleRepositoryStatus, _ mark: ProjectShareImportEditor.RepositoryRowModel.Mark) {
        #expect(ProjectShareImportEditor.mark(of: status) == mark)
        #expect(!ProjectShareImportEditor.detail(of: status).isEmpty)
    }

    /// A 0.9 file with Supabase or Vercel destinations imports without them (SharingKit drops
    /// them); the repository preview names each one.
    @Test func theRepositoryPreviewNamesTheDestinationsLeftOut() {
        let line = ProjectShareCopy.retiredDestinations(["Supabase abcdefghijklmnopqrst", "Vercel example-web (preview)"])
        #expect(line == "Left out: Supabase abcdefghijklmnopqrst, Vercel example-web (preview). Supabase and Vercel are no longer supported.")
    }

    @Test func theImportAccountIsNamedWhenKnown() {
        #expect(ProjectShareImportEditor.detail(of: .willImportFromGitHub(accountLogin: "user-a")).contains("user-a"))
    }
}

/// Settings › Sharing (v0.9.0, P6): the sent log, newest first, with its protection and names, and
/// removing an entry.
@MainActor
@Suite("Project share sent log", .serialized)
struct ProjectShareSentLogTests {
    @Test func listsSentFilesNewestFirstWithNamesAndRemovesOne() async throws {
        let world = try await ProjectShareWorld()
        _ = try await world.exportBundle()
        world.sender.clock.advance(by: .seconds(Timeouts.secondsPerMinute))
        _ = try await world.exportBundle()
        let model = SharingSettingsViewModel(
            sharing: world.sender.data.sharing,
            clock: world.sender.clock,
            isUnlocked: { true }
        )
        let sent = try await world.sender.data.sharing.sentShares()
        model.show(sent)

        #expect(model.entries.count == 2)
        #expect(model.entries.map(\.id) == sent.map(\.id))
        let newest = try #require(model.entries.first)
        #expect(model.entries.allSatisfy { $0.recipients == ProjectShareCopy.passphraseMode })
        #expect(newest.repositories == ["\(TestFixtures.owner)/\(TestFixtures.repoName)"])
        #expect(newest.stages == ["staging"])
        #expect(newest.places.flatMap(\.secretNames).contains("DATABASE_URL"))
        #expect(!newest.isExpired)

        model.requestRemoval(newest)
        await model.confirmRemoval()
        #expect(try await world.sender.data.sharing.sentShares().count == 1)
    }

    /// A 0.9 teammates row still lists, its recipients unresolved (1.0 keeps no teammates).
    @Test func anExpiredZeroNineTeammatesEntryIsMarked() {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let share = SentShareModel(
            packageID: SharePackageID(),
            createdAt: created,
            expiresAt: ShareExpiryChoice.oneDay.expiry(from: created),
            mode: .teammates,
            recipientIDs: ["0123456789abcdef0123456789abcdef"],
            summary: SentShareSummaryModel(stages: [], places: [])
        )
        let entry = SharingSettingsViewModel.entry(share, now: created.addingTimeInterval(2 * 86_400))
        #expect(entry.isExpired)
        #expect(entry.recipients == ProjectShareCopy.teammatesMode([ProjectShareCopy.unknownTeammate("0123456789abcdef0123456789abcdef")]))
    }
}
