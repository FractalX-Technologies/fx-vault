import Foundation
import FXVaultTestSupport
import SyncEngine
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// Rows held by share files (v0.9.0, tasks/todo.md P8) on the GitHub side of Sync: left out of
/// every plan, listed in the From Files review, released by including the file, by
/// ``ShareHoldRepository`` or by the user's own delete and revert.
@Suite("Held share files in Sync", .timeLimit(.minutes(1)))
struct HeldShareSyncTests {
    private static let first = SharePackageID()
    private static let second = SharePackageID()

    private func importedHarness() async throws -> SyncHarness {
        let github = GitHubSimulator(owner: SyncFixture.owner, name: SyncFixture.repoName)
        github.addSecret("FXV_API_TOKEN")
        github.addVariable("FXV_API_URL", value: "https://one.example.invalid")
        github.addEnvironment("staging")
        let harness = try await SyncHarness.make(github: github)
        try await harness.importRepository()
        return harness
    }

    /// Holds `ids` under `packageID` and records the import, as the share importer does.
    private func hold(
        _ ids: [ConfigItemID],
        under packageID: SharePackageID,
        in harness: SyncHarness,
        sender: String = "Teammate",
        senderDeviceID: String? = nil,
        importedAt: Date? = nil
    ) throws {
        try harness.database.write { tx in
            try ConfigStore(database: harness.database).setShareHold(packageID, itemIDs: ids, in: tx)
            try SharePackageStore(database: harness.database).recordImport(ImportedSharePackageRecord(
                packageID: packageID,
                createdAt: harness.clock.now,
                importedAt: importedAt ?? harness.clock.now,
                senderName: sender,
                senderDeviceID: senderDeviceID
            ), in: tx)
        }
    }

    private func runSync(_ harness: SyncHarness, including included: Set<SharePackageID> = []) async throws -> SyncRunOutcomeModel {
        let review = try await harness.sync.preflight()
        let handle = try await harness.sync.startRun(review, includeDeletions: true, includeHeld: included)
        return await handle.outcome()
    }

    private func names(_ preflight: SyncPreflightModel) -> [String] {
        preflight.repositories.flatMap(\.executable).compactMap { change in
            switch change.operation {
            case .setItem(let set): set.name
            case .deleteItem(let delete): "-\(delete.name)"
            default: nil
            }
        }.sorted()
    }

    @Test func heldItemsNeverReachTheSyncPlan() async throws {
        let harness = try await importedHarness()
        let held = try harness.add("FXV_HELD", kind: .secret, value: "fixture-held")
        let url = try #require(try harness.item("FXV_API_URL", kind: .variable))
        try harness.config.editValue(url.id, value: SecretBytes(utf8: "https://from-file.example.invalid"))
        try harness.add("FXV_MINE", kind: .secret, value: "fixture-mine")
        try hold([held, url.id], under: Self.first, in: harness)

        let review = try await harness.sync.preflight()
        #expect(names(review.preflight) == ["FXV_MINE"])
        #expect(review.summary.pendingCount == 1)
        #expect(names(review.preflight(including: [Self.first])) == ["FXV_API_URL", "FXV_HELD", "FXV_MINE"])
        #expect(review.preflight(including: [Self.first]).estimatedWriteCost > review.preflight.estimatedWriteCost)
        let share = try #require(review.heldShares.first)
        #expect(review.heldShares.count == 1)
        #expect(share.packageID == Self.first)
        #expect(share.senderName == "Teammate")
        #expect(!share.isSenderVerified)
        #expect(share.itemCount == 2)
        #expect(share.repositories.first?.scopes.first?.items.map(\.name) == ["FXV_API_URL", "FXV_HELD"])
        #expect(share.repositories.first?.scopes.first?.items.map(\.isNew) == [false, true])

        let handle = try await harness.sync.startRun(review, includeDeletions: true)
        let outcome = await handle.outcome()
        #expect(outcome.result.failed.isEmpty)
        #expect(harness.github.secret("FXV_MINE")?.value == "fixture-mine")
        #expect(harness.github.secret("FXV_HELD") == nil)
        #expect(harness.github.variable("FXV_API_URL")?.value == "https://one.example.invalid")
        #expect(!harness.github.writes.contains { $0.contains("FXV_HELD") || $0.contains("FXV_API_URL") })
        #expect(try harness.record(held).shareHold == Self.first)
        #expect(try harness.record(url.id).shareHold == Self.first)

        // Not included: offered again at the next Sync.
        let next = try await harness.sync.preflight()
        #expect(next.heldShares.map(\.packageID) == [Self.first])
        #expect(names(next.preflight).isEmpty)
    }

    @Test func includingAFileReleasesExactlyItsRowsAndTheyPush() async throws {
        let harness = try await importedHarness()
        let one = try harness.add("FXV_ONE", kind: .secret, value: "fixture-one")
        let two = try harness.add("FXV_TWO", kind: .secret, value: "fixture-two")
        try hold([one], under: Self.first, in: harness, importedAt: harness.clock.now)
        try hold([two], under: Self.second, in: harness, importedAt: harness.clock.now.addingTimeInterval(60))

        let review = try await harness.sync.preflight()
        #expect(review.heldShares.map(\.packageID) == [Self.second, Self.first])
        let outcome = try await {
            let handle = try await harness.sync.startRun(review, includeDeletions: true, includeHeld: [Self.first])
            return await handle.outcome()
        }()

        #expect(outcome.result.failed.isEmpty)
        #expect(harness.github.secret("FXV_ONE")?.value == "fixture-one")
        #expect(harness.github.secret("FXV_TWO") == nil)
        #expect(try harness.record(one).shareHold == nil)
        #expect(try harness.record(one).syncedName == "FXV_ONE")
        #expect(try harness.record(two).shareHold == Self.second)
        #expect(try await harness.sync.preflight().heldShares.map(\.packageID) == [Self.second])
    }

    @Test func aNewEnvironmentWaitsWhileEverythingInItIsHeld() async throws {
        let harness = try await importedHarness()
        let repository = try harness.repository()
        let preview = try harness.config.createEnvironment(in: repository.id, name: "preview")
        let held = try harness.add("FXV_PREVIEW_URL", kind: .variable, value: "https://preview.example.invalid", scope: .environment(preview))
        try hold([held], under: Self.first, in: harness)

        let review = try await harness.sync.preflight()
        #expect(review.preflight.executableCount == 0)
        #expect(review.heldShares.first?.repositories.first?.scopes.first?.holdsEnvironment == true)
        #expect(review.heldShares.first?.repositories.first?.scopes.first?.environmentName == "preview")
        _ = await (try harness.sync.startRun(review, includeDeletions: true)).outcome()
        #expect(harness.github.environment("preview") == nil)

        // One row of the user's own: the environment is created, the held row still waits.
        try harness.add("FXV_PREVIEW_MINE", kind: .variable, value: "mine", scope: .environment(preview))
        let next = try await harness.sync.preflight()
        #expect(next.heldShares.first?.repositories.first?.scopes.first?.holdsEnvironment == false)
        _ = await (try harness.sync.startRun(next, includeDeletions: true)).outcome()
        #expect(harness.github.environment("preview") != nil)
        #expect(harness.github.variable("FXV_PREVIEW_MINE", environment: "preview")?.value == "mine")
        #expect(harness.github.variable("FXV_PREVIEW_URL", environment: "preview") == nil)

        let last = try await runSync(harness, including: [Self.first])
        #expect(last.result.failed.isEmpty)
        #expect(harness.github.variable("FXV_PREVIEW_URL", environment: "preview")?.value == "https://preview.example.invalid")
    }

    @Test func aRenameWaitsWhileTheEnvironmentHoldsARow() async throws {
        let harness = try await importedHarness()
        let staging = try #require(try harness.environment("staging"))
        let held = try harness.add("FXV_STAGE_KEY", kind: .secret, value: "fixture-stage", scope: .environment(staging.id))
        try hold([held], under: Self.first, in: harness)
        try harness.config.renameEnvironment(staging.id, to: "qa")

        let review = try await harness.sync.preflight()
        #expect(review.preflight.executableCount == 0)
        #expect(review.heldShares.first?.repositories.first?.scopes.first?.holdsEnvironment == true)
        _ = await (try harness.sync.startRun(review, includeDeletions: true)).outcome()
        #expect(harness.github.environment("staging") != nil)
        #expect(harness.github.environment("qa") == nil)

        let outcome = try await runSync(harness, including: [Self.first])
        #expect(outcome.result.failed.isEmpty)
        #expect(harness.github.environment("qa") != nil)
        #expect(harness.github.secret("FXV_STAGE_KEY", environment: "qa")?.value == "fixture-stage")
    }

    @Test func releasingByFileOrByItemOutsideSync() async throws {
        let harness = try await importedHarness()
        let one = try harness.add("FXV_ONE", kind: .secret, value: "fixture-one")
        let two = try harness.add("FXV_TWO", kind: .secret, value: "fixture-two")
        let three = try harness.add("FXV_THREE", kind: .secret, value: "fixture-three")
        try hold([one, two], under: Self.first, in: harness)
        try hold([three], under: Self.second, in: harness)
        let holds = ShareHoldRepository(session: harness.session)

        #expect(try holds.releaseHold(itemIDs: [three]) == 1)
        #expect(try holds.heldShares().map(\.packageID) == [Self.first])
        #expect(try holds.releaseHold(packageID: Self.first) == 2)
        #expect(try holds.heldShares().isEmpty)
        #expect(names(try await harness.sync.preflight().preflight) == ["FXV_ONE", "FXV_THREE", "FXV_TWO"])
    }

    @Test func deletingOrRevertingAHeldRowIsTheUsersOwnChange() async throws {
        let harness = try await importedHarness()
        let url = try #require(try harness.item("FXV_API_URL", kind: .variable))
        try harness.config.editValue(url.id, value: SecretBytes(utf8: "https://from-file.example.invalid"))
        let token = try #require(try harness.item("FXV_API_TOKEN", kind: .secret))
        try harness.config.fillValue(token.id, value: SecretBytes(utf8: "fixture-token"))
        let added = try harness.add("FXV_ADDED", kind: .secret, value: "fixture-added")
        try hold([url.id, token.id, added], under: Self.first, in: harness)

        try harness.config.revertItem(url.id)
        try harness.config.deleteItem(token.id)
        try harness.config.deleteItem(added)

        #expect(try harness.record(url.id).shareHold == nil)
        #expect(try harness.record(token.id).shareHold == nil)
        #expect(try harness.store.fetchItemRecord(id: added) == nil)
        #expect(try ShareHoldRepository(session: harness.session).heldShares().isEmpty)
        let review = try await harness.sync.preflight()
        #expect(names(review.preflight) == ["-FXV_API_TOKEN"])
        _ = await (try harness.sync.startRun(review, includeDeletions: true)).outcome()
        #expect(harness.github.secret("FXV_API_TOKEN") == nil)
    }

    @Test func renamingAHeldRowKeepsItHeld() async throws {
        let harness = try await importedHarness()
        let held = try harness.add("FXV_HELD", kind: .secret, value: "fixture-held")
        try hold([held], under: Self.first, in: harness)
        let renamed = try harness.config.renameItem(held, to: "FXV_HELD_RENAMED")

        #expect(try harness.record(renamed).shareHold == Self.first)
        let review = try await harness.sync.preflight()
        #expect(names(review.preflight).isEmpty)
        #expect(review.heldShares.first?.repositories.first?.scopes.first?.items.map(\.name) == ["FXV_HELD_RENAMED"])
    }

    @Test func aValueTheUserTypesReleasesTheHold() async throws {
        let harness = try await importedHarness()
        let held = try harness.add("FXV_HELD", kind: .secret, value: "fixture-from-file")
        try hold([held], under: Self.first, in: harness)
        try harness.config.editValue(held, value: SecretBytes(utf8: "fixture-mine"))

        #expect(try harness.record(held).shareHold == nil)
        let review = try await harness.sync.preflight()
        #expect(names(review.preflight) == ["FXV_HELD"])
        #expect(review.heldShares.isEmpty)
    }

    @Test func credentialWarningsOfHeldVariablesWaitForTheFile() async throws {
        let harness = try await importedHarness()
        let held = try harness.add("FXV_DB_PASSWORD", kind: .variable, value: "plain-looking-value")
        try hold([held], under: Self.first, in: harness, senderDeviceID: String(repeating: "ab", count: 16))

        let review = try await harness.sync.preflight()
        #expect(review.credentialWarnings.isEmpty)
        #expect(review.credentialWarnings(including: [Self.first]).map(\.name) == ["FXV_DB_PASSWORD"])
        #expect(review.heldShares.first?.isSenderVerified == true)
    }

    @Test func dekRotationKeepsHolds() async throws {
        let harness = try await importedHarness()
        let held = try harness.add("FXV_HELD", kind: .secret, value: "fixture-held")
        try hold([held], under: Self.first, in: harness)
        let before = try ShareHoldRepository(session: harness.session).heldShares()

        _ = try await harness.manager.rotateDEK(password: SyncFixture.password)

        #expect(try harness.record(held).shareHold == Self.first)
        #expect(try ShareHoldRepository(session: harness.session).heldShares() == before)
        #expect(try harness.value(held) == "fixture-held")
        let review = try await harness.sync.preflight()
        #expect(names(review.preflight).isEmpty)
    }

    @Test func observingHeldSharesFollowsReleases() async throws {
        let harness = try await importedHarness()
        let held = try harness.add("FXV_HELD", kind: .secret, value: "fixture-held")
        try hold([held], under: Self.first, in: harness)
        let holds = ShareHoldRepository(session: harness.session)
        var iterator = holds.observeHeldShares().makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.packageID) == [Self.first])
        try holds.releaseHold(packageID: Self.first)
        #expect(try await iterator.next()?.isEmpty == true)
    }
}
