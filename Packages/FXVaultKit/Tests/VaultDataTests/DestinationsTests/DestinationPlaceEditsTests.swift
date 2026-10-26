import Foundation
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// The notes' Review saves a Key Vault's edits in one transaction (1.0 N2); they stay pending
/// until the next Sync.
@Suite("DestinationRepository place edits")
struct DestinationPlaceEditsTests {
    @Test func everyEditOfAKeyVaultIsSavedAsPendingChanges() async throws {
        let fixture = try await DestinationRepositoryTests.Fixture.make()
        let vault = try fixture.keyVault()
        let renamed = try fixture.add(vault, "API_KEY", value: ConfigFixture.valueA)
        let removed = try fixture.add(vault, "OLD_TOKEN", value: ConfigFixture.valueB)
        try fixture.markSynced(vault)

        let edits = PlaceItemEditsModel(
            deletions: [removed],
            changes: [.init(id: renamed, name: "API_TOKEN", value: SecretBytes(utf8: ConfigFixture.valueC))],
            additions: [.init(kind: .secret, name: "CACHE_URL", value: SecretBytes(utf8: ConfigFixture.valueB))]
        )
        defer { edits.wipe() }
        try fixture.destinations.applyEdits(edits, destinationID: vault)

        let live = try fixture.destinations.items(destinationID: vault).filter { !$0.isDeleted }
        #expect(live.map(\.name).sorted() == ["API_TOKEN", "CACHE_URL"])
        let token = try #require(live.first { $0.name == "API_TOKEN" })
        #expect(try fixture.reveal(token.id) == ConfigFixture.valueC)
        #expect(try fixture.status(removed) == .deleted)
    }

    @Test func nothingIsWrittenWhenOneEditFails() async throws {
        let fixture = try await DestinationRepositoryTests.Fixture.make()
        let vault = try fixture.keyVault()
        let removed = try fixture.add(vault, "OLD_TOKEN", value: ConfigFixture.valueA)
        try fixture.markSynced(vault)

        let tooLong = String(repeating: "A", count: DestinationRules.maxKeyVaultNameLength + 1)
        let edits = PlaceItemEditsModel(
            deletions: [removed],
            additions: [.init(kind: .secret, name: tooLong, value: SecretBytes(utf8: ConfigFixture.valueB))]
        )
        defer { edits.wipe() }
        let error = configError { try fixture.destinations.applyEdits(edits, destinationID: vault) }

        #expect(error == .validation(.invalidName(.tooLong(maxLength: DestinationRules.maxKeyVaultNameLength))))
        #expect(try fixture.status(removed) == .synced)
    }

    /// The same vault serving a repository and standing on its own are two places: an edit of one
    /// never reaches the other's items.
    @Test func anItemOfAnotherKeyVaultIsRefused() async throws {
        let fixture = try await DestinationRepositoryTests.Fixture.make()
        let vault = try fixture.keyVault()
        let standalone = try fixture.destinations.createDestination(repositoryID: nil, target: DestinationRepositoryTests.keyVault, stage: nil)
        let elsewhere = try fixture.add(standalone, "API_KEY", value: ConfigFixture.valueA)
        try fixture.markSynced(standalone)

        for edits in [
            PlaceItemEditsModel(deletions: [elsewhere]),
            PlaceItemEditsModel(changes: [.init(id: elsewhere, value: SecretBytes(utf8: ConfigFixture.valueB))]),
        ] {
            defer { edits.wipe() }
            let error = configError { try fixture.destinations.applyEdits(edits, destinationID: vault) }
            #expect(error == .itemNotFound)
        }
        #expect(try fixture.status(elsewhere) == .synced)
        #expect(try fixture.reveal(elsewhere) == ConfigFixture.valueA)
    }
}
