import Foundation
import SyncEngine
import Testing
import VaultCore
@_spi(Testing) import VaultData
@testable import FXVault

/// Rows held by share files in the app (v0.9.0, tasks/todo.md P8): Sync's From Files review
/// (one toggle per file, off by default, passed to the run), the destination summary with the
/// included files, and the Held chip, whose Push on Next Sync only releases the hold.
@MainActor
@Suite("Held share files")
struct HeldShareTests {
    static let first = SharePackageID()
    static let second = SharePackageID()
    static let importedAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let teammateDevice = String(repeating: "ab", count: 16)
    static let vault = DestinationTargetModel.azureKeyVault(vaultName: "kv-example-staging", tenantID: nil)

    static func share(
        _ packageID: SharePackageID,
        sender: String?,
        verified: Bool,
        names: [String],
        repository: RepoModel = SyncFixtures.repository
    ) -> HeldShareModel {
        HeldShareModel(
            packageID: packageID,
            senderName: sender,
            senderDeviceID: verified ? teammateDevice : nil,
            createdAt: importedAt,
            importedAt: importedAt,
            repositories: [HeldShareRepositoryModel(
                repository: repository,
                scopes: [HeldShareScopeModel(
                    scope: .repository,
                    environmentName: nil,
                    items: names.map { HeldShareItemModel(id: ConfigItemID(), kind: .secret, name: $0, isNew: true) },
                    holdsEnvironment: false
                )],
                destinations: []
            )]
        )
    }

    private static func review(held: [HeldShareModel], executable: [ConfigChangeModel] = [SyncFixtures.set(.secret, "API_TOKEN")]) -> SyncReviewModel {
        var review = SyncFixtures.review([SyncFixtures.preflight(executable: executable)])
        review.heldShares = held
        return review
    }

    // MARK: - From Files review

    @Test func fromFilesListsEveryFileOffByDefault() async throws {
        let held = [
            Self.share(Self.first, sender: "Teammate A", verified: true, names: ["HELD_KEY"]),
            Self.share(Self.second, sender: nil, verified: false, names: ["FIRST_KEY", "SECOND_KEY"]),
        ]
        let fixture = try await SyncViewModelTests.Fixture(review: .success(Self.review(held: held)))
        let model = fixture.viewModel
        await model.load()

        let rows = model.heldShareRows
        #expect(rows.map(\.title) == ["From Teammate A's file", "From a share file"])
        #expect(rows.map(\.isVerified) == [true, false])
        #expect(rows[0].meta.hasSuffix("1 item"))
        #expect(rows[1].meta.hasSuffix("2 items"))
        #expect(rows.allSatisfy { !$0.isIncluded })
        #expect(rows[0].groups.map(\.names) == ["+ HELD_KEY"])
        #expect(rows[1].groups.map(\.names) == ["+ FIRST_KEY   + SECOND_KEY"])
        #expect(model.includedHeldShares.isEmpty)
        #expect(!model.waitsOnlyForHeldShares, "API_TOKEN still syncs")
    }

    @Test func includingAFilePassesExactlyItToTheRun() async throws {
        let held = [
            Self.share(Self.first, sender: "Teammate A", verified: true, names: ["HELD_KEY"]),
            Self.share(Self.second, sender: "Teammate B", verified: false, names: ["OTHER_KEY"]),
        ]
        let fixture = try await SyncViewModelTests.Fixture(review: .success(Self.review(held: held)))
        let model = fixture.viewModel
        await model.load()

        model.setIncluded(Self.first, true)
        model.setIncluded(Self.second, true)
        model.setIncluded(Self.second, false)
        #expect(model.includedHeldShares == [Self.first])
        #expect(model.heldShareRows.map(\.isIncluded) == [true, false])

        let task = await fixture.startRun()
        #expect(fixture.service.startedRuns.last?.includeHeld == [Self.first])
        fixture.service.run.finish(SyncFixtures.outcome([]))
        await task.value
    }

    @Test func aSyncThatIncludesNothingKeepsEveryFileHeld() async throws {
        let held = [Self.share(Self.first, sender: "Teammate A", verified: true, names: ["HELD_KEY"])]
        let fixture = try await SyncViewModelTests.Fixture(review: .success(Self.review(held: held)))
        await fixture.viewModel.load()

        let task = await fixture.startRun()
        #expect(fixture.service.startedRuns.last?.includeHeld == [])
        fixture.service.run.finish(SyncFixtures.outcome([]))
        await task.value
    }

    @Test func onlyHeldChangesExplainWhatToInclude() async throws {
        let held = [Self.share(Self.first, sender: "Teammate A", verified: true, names: ["HELD_KEY"])]
        let fixture = try await SyncViewModelTests.Fixture(review: .success(Self.review(held: held, executable: [])))
        let model = fixture.viewModel
        await model.load()

        #expect(model.waitsOnlyForHeldShares)
        #expect(!model.canProceed)
        #expect(HeldShareCopy.onlyHeld.contains("Include a file"))
    }

    @Test func filesOfOtherRepositoriesAreNotOfferedInARepositorySync() async throws {
        let held = [Self.share(Self.first, sender: "Teammate A", verified: true, names: ["HELD_KEY"])]
        let fixture = try await SyncViewModelTests.Fixture(
            review: .success(Self.review(held: held)),
            repositoryIDs: [RepoID()]
        )
        await fixture.viewModel.load()

        #expect(fixture.viewModel.heldShares.isEmpty)
        fixture.viewModel.setIncluded(Self.first, true)
        #expect(fixture.viewModel.includedHeldShares.isEmpty, "an unknown file cannot be included")
    }

    @Test func aReloadKeepsTheChoicesOfFilesStillHeld() async throws {
        let held = [
            Self.share(Self.first, sender: "Teammate A", verified: true, names: ["HELD_KEY"]),
            Self.share(Self.second, sender: "Teammate B", verified: true, names: ["OTHER_KEY"]),
        ]
        let fixture = try await SyncViewModelTests.Fixture(review: .success(Self.review(held: held)))
        let model = fixture.viewModel
        await model.load()
        model.setIncluded(Self.first, true)
        model.setIncluded(Self.second, true)

        fixture.service.setReview(.success(Self.review(held: [held[0]])))
        await model.load()

        #expect(model.includedHeldShares == [Self.first])
    }

    // MARK: - Destinations with included files

    @Test func includedHeldDestinationWritesJoinTheSummaryAndTheCount() throws {
        let repositoryID = RepoID()
        let destination = DestinationModel(
            repositoryID: repositoryID,
            target: Self.vault,
            stage: "staging",
            connectionID: nil,
            sortOrder: 0,
            createdAt: Self.importedAt,
            updatedAt: Self.importedAt
        )
        func change(_ name: String, isNew: Bool) -> DestinationChangeModel {
            DestinationChangeModel(
                destinationID: destination.id,
                itemID: ConfigItemID(),
                name: name,
                remoteName: name.replacingOccurrences(of: "_", with: "-"),
                kind: .secret,
                operation: isNew ? .add : .update
            )
        }
        let own = change("OWN_KEY", isNew: false)
        let review = DestinationReviewModel(repositoryID: repositoryID, sections: [
            DestinationReviewSectionModel(
                destination: destination,
                changes: [own],
                blocked: [],
                warnings: [],
                held: [
                    DestinationHeldChangeModel(change: change("HELD_KEY", isNew: true), packageID: Self.first),
                    DestinationHeldChangeModel(change: change("NO_VALUE", isNew: true), packageID: Self.first, reason: .valueMissing),
                    DestinationHeldChangeModel(change: change("OTHER_FILE", isNew: true), packageID: Self.second),
                ]
            ),
        ])

        #expect(HeldSharePresentation.effective(review, including: []) == review)
        let included = HeldSharePresentation.effective(review, including: [Self.first])
        let section = try #require(included.sections.first)
        #expect(section.changes.map(\.name) == ["OWN_KEY", "HELD_KEY"])
        #expect(section.blocked.map(\.change.name) == ["NO_VALUE"])
        #expect(included.executableCount == 2)
        #expect(HeldSharePresentation.hasContent(DestinationReviewModel(repositoryID: repositoryID, sections: [
            DestinationReviewSectionModel(destination: destination, changes: [], blocked: [], warnings: [], held: review.sections[0].held),
        ])), "a destination with only held rows stays in the Sync")
    }

    // MARK: - Held chip

    @Test func aHeldRowShowsTheChipAndPushOnNextSyncOnlyReleasesItsHold() async throws {
        let (harness, repositoryID) = try await EditorFixtures.importedHarness()
        let added = try harness.data.config.addItem(
            repositoryID: repositoryID,
            scope: .repository,
            kind: .secret,
            name: "FXV_HELD_KEY",
            value: SecretBytes(utf8: EditorFixtures.secretValue)
        ).itemID
        try ShareHoldRepository(session: harness.vaultManager.session).hold(
            [added],
            under: Self.first,
            senderName: "Teammate A",
            senderDeviceID: Self.teammateDevice,
            importedAt: Self.importedAt
        )
        let viewModel = RepoDetailViewModel(
            repositoryID: repositoryID,
            dependencies: harness.dependencies(recorder: ActionRecorder()),
            repository: { harness.repository(repositoryID) },
            scopeSummary: { scope in try? harness.data.config.scopes(repositoryID: repositoryID).first { $0.scope == scope } }
        )
        viewModel.kind = .secret
        #expect(await TestFixtures.eventually { viewModel.rows.contains { $0.name == "FXV_HELD_KEY" && $0.isHeld } })
        let row = try #require(viewModel.rows.first { $0.name == "FXV_HELD_KEY" })
        #expect(row.heldBy == Self.first)
        #expect(row.canPushOnNextSync, "Push on Next Sync is offered on a held row")
        #expect(viewModel.heldHelp(for: row).contains("Teammate A"))

        viewModel.pushOnNextSync(row)

        #expect(await TestFixtures.eventually { viewModel.rows.contains { $0.name == "FXV_HELD_KEY" && !$0.isHeld } })
        let released = try #require(viewModel.rows.first { $0.name == "FXV_HELD_KEY" })
        #expect(released.status == .added, "still a pending add, not a forced push")
        #expect(viewModel.notice == HeldShareCopy.released(name: "FXV_HELD_KEY", count: 1))
        #expect(viewModel.alert == nil)
        #expect(try ShareHoldRepository(session: harness.vaultManager.session).heldShares().isEmpty)
    }

    @Test func copyHasSingularForms() {
        #expect(HeldShareCopy.meta(importedAt: nil, itemCount: 1) == "1 item")
        #expect(HeldShareCopy.meta(importedAt: nil, itemCount: 3) == "3 items")
        #expect(HeldShareCopy.disclosure(isExpanded: false, itemCount: 1) == "Show 1 Item")
        #expect(HeldShareCopy.released(name: nil, count: 1) == "The next Sync pushes 1 item. It is no longer held.")
        #expect(HeldShareCopy.released(name: nil, count: 2) == "The next Sync pushes 2 items. They are no longer held.")
        #expect(HeldShareCopy.chipHelp(sender: nil).hasPrefix("Imported from a share file."))
    }
}
