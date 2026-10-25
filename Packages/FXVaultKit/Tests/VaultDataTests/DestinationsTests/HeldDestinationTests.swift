import Foundation
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// Rows held by share files (v0.9.0, tasks/todo.md P8) on the destination side of Sync and in the
/// stage Overview.
@Suite("Held share files in destinations")
struct HeldDestinationTests {
    private static let first = SharePackageID()

    private func hold(_ ids: [ConfigItemID], under packageID: SharePackageID, in harness: ConfigHarness) throws {
        try harness.database.write { tx in
            try DestinationStore(database: harness.database).setShareHold(packageID, itemIDs: ids, in: tx)
            try SharePackageStore(database: harness.database).recordImport(ImportedSharePackageRecord(
                packageID: packageID,
                createdAt: harness.clock.now,
                importedAt: harness.clock.now,
                senderName: "Teammate"
            ), in: tx)
        }
    }

    private func holdConfig(_ ids: [ConfigItemID], under packageID: SharePackageID, in harness: ConfigHarness) throws {
        try harness.database.write { tx in
            try ConfigStore(database: harness.database).setShareHold(packageID, itemIDs: ids, in: tx)
        }
    }

    @Test func heldDestinationRowsStayOutUntilTheirFileIsIncluded() async throws {
        let fixture = try await DestinationSyncRepositoryTests.Fixture.make()
        let (vault, remote) = try fixture.keyVault()
        try fixture.add(vault, "DATABASE_URL", value: "postgres://a")
        try fixture.add(vault, "SYNCED_KEY", value: "old")
        _ = await fixture.syncAll()
        let synced = try fixture.item(vault, "SYNCED_KEY")
        try fixture.destinations.editItem(synced.id, name: "SYNCED_KEY", kind: .secret, value: SecretBytes(utf8: "from-file"))
        let added = try fixture.add(vault, "HELD_KEY", value: "held")
        try fixture.add(vault, "MINE_KEY", value: "mine")
        try hold([synced.id, added], under: Self.first, in: fixture.harness)

        var review = await fixture.sync.review(repositoryID: fixture.repo.id)
        let section = try #require(review.sections.first)
        #expect(section.changes.map(\.name) == ["MINE_KEY"])
        #expect(section.held.map(\.change.name) == ["HELD_KEY", "SYNCED_KEY"])
        #expect(section.held.allSatisfy { $0.packageID == Self.first && $0.reason == nil })
        #expect(section.heldWrites(including: [Self.first]).count == 2)
        #expect(section.heldWrites(including: []).isEmpty)

        var result = await fixture.sync.run(review, includeDeletions: true)
        #expect(result.doneCount == 1)
        #expect(remote.names == ["DATABASE-URL", "MINE-KEY", "SYNCED-KEY"])
        #expect(remote.value(of: "SYNCED_KEY") == "old")
        #expect(try fixture.item(vault, "HELD_KEY").heldBy == Self.first)

        // Offered again; included this time.
        review = await fixture.sync.review(repositoryID: fixture.repo.id)
        #expect(review.sections.first?.hasOnlyHeldChanges == true)
        result = await fixture.sync.run(review, includeDeletions: true, includeHeld: [Self.first])
        #expect(result.doneCount == 2)
        #expect(remote.value(of: "HELD_KEY") == "held")
        #expect(remote.value(of: "SYNCED_KEY") == "from-file")
        #expect(try fixture.item(vault, "HELD_KEY").isHeld == false)
        #expect(try ShareHoldRepository(session: fixture.harness.session).heldShares().isEmpty)
    }

    @Test func deletingAHeldDestinationRowIsNotHeld() async throws {
        let fixture = try await DestinationSyncRepositoryTests.Fixture.make()
        let (vault, remote) = try fixture.keyVault()
        let key = try fixture.add(vault, "OLD_KEY", value: "old")
        _ = await fixture.syncAll()
        try fixture.destinations.editItem(key, name: "OLD_KEY", kind: .secret, value: SecretBytes(utf8: "from-file"))
        try hold([key], under: Self.first, in: fixture.harness)
        try fixture.destinations.deleteItems([key])

        let review = await fixture.sync.review(repositoryID: fixture.repo.id)
        #expect(review.sections.first?.deletions.map(\.name) == ["OLD_KEY"])
        #expect(review.sections.first?.held.isEmpty == true)
        #expect(try ShareHoldRepository(session: fixture.harness.session).heldShares().isEmpty)
        _ = await fixture.sync.run(review, includeDeletions: true)
        #expect(remote.names.isEmpty)
    }

    @Test func aTypedValueReleasesAHeldDestinationRowAndARenameKeepsIt() async throws {
        let fixture = try await DestinationSyncRepositoryTests.Fixture.make()
        let (vault, _) = try fixture.keyVault()
        let typed = try fixture.add(vault, "TYPED_KEY", value: "from-file")
        let renamed = try fixture.add(vault, "OLD_NAME", value: "old")
        _ = await fixture.syncAll()
        try fixture.destinations.editItem(renamed, name: "OLD_NAME", kind: .secret, value: SecretBytes(utf8: "from-file"))
        try hold([typed, renamed], under: Self.first, in: fixture.harness)

        _ = try fixture.destinations.editItem(typed, name: "TYPED_KEY", kind: .secret, value: SecretBytes(utf8: "mine"))
        _ = try fixture.destinations.editItem(renamed, name: "NEW_NAME", kind: .secret, value: nil)

        #expect(try fixture.item(vault, "TYPED_KEY").isHeld == false)
        #expect(try fixture.item(vault, "NEW_NAME").heldBy == Self.first)
        let review = await fixture.sync.review(repositoryID: fixture.repo.id)
        #expect(review.sections.first?.held.map(\.change.name) == ["NEW_NAME"])
    }

    @Test func aHeldRowThatCannotBeSentKeepsItsReason() async throws {
        let fixture = try await DestinationSyncRepositoryTests.Fixture.make()
        let (vault, remote) = try fixture.keyVault()
        let blocked = try fixture.add(vault, "TAKEN_KEY", value: "mine")
        remote.put("TAKEN_KEY", value: "theirs")
        try hold([blocked], under: Self.first, in: fixture.harness)

        let review = await fixture.sync.review(repositoryID: fixture.repo.id)
        let held = try #require(review.sections.first?.held.first)
        #expect(held.reason == .existsRemotely)
        #expect(review.sections.first?.blocked.isEmpty == true)
        let result = await fixture.sync.run(review, includeDeletions: true, includeHeld: [Self.first])
        #expect(result.doneCount == 0)
        #expect(remote.value(of: "TAKEN_KEY") == "theirs")
    }

    @Test func heldSharesGroupRowsByRepositoryScopeAndDestination() async throws {
        let fixture = try await DestinationSyncRepositoryTests.Fixture.make()
        let (vault, _) = try fixture.keyVault()
        let destinationRow = try fixture.add(vault, "DATABASE_URL", value: "postgres://held")
        let configRow = try fixture.harness.add(fixture.repo, "DEPLOY_TOKEN", value: "deploy-token-held")
        try hold([destinationRow], under: Self.first, in: fixture.harness)
        try holdConfig([configRow], under: Self.first, in: fixture.harness)

        let shares = try ShareHoldRepository(session: fixture.harness.session).heldShares()
        let share = try #require(shares.first)
        #expect(shares.count == 1)
        #expect(share.itemCount == 2)
        #expect(share.itemIDs == [destinationRow, configRow])
        let repository = try #require(share.repositories.first)
        #expect(repository.repository.id == fixture.repo.id)
        #expect(repository.scopes.map(\.scope) == [.repository])
        #expect(repository.scopes.first?.items.map(\.name) == ["DEPLOY_TOKEN"])
        #expect(repository.destinations.map(\.destination.id) == [vault])
        #expect(repository.destinations.first?.items.map(\.name) == ["DATABASE_URL"])
    }
}
