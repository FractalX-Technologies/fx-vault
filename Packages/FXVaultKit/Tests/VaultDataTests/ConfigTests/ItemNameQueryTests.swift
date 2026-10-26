import Foundation
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// ⌘K "Secrets by name" (1.0 D6c5, board Main2-Search): one query over the names of every
/// repository scope, folder, Key Vault and organization; never a value.
@Suite("Item names")
struct ItemNameQueryTests {
    @Test func everyHolderAnswersEveryWordInAnyCase() async throws {
        let fixture = try await OrganizationItemRepositoryTests.Fixture.make()
        let harness = fixture.base.harness
        let repo = try harness.seedRepository()
        let production = try harness.config.createEnvironment(in: repo.id, name: "production")
        let staging = try harness.config.createEnvironment(in: repo.id, name: "staging")
        let environmentKey = try harness.add(repo, "STRIPE_KEY", value: ConfigFixture.valueA, scope: .environment(production))
        try harness.add(repo, "STRIPE_WEBHOOK_SECRET", value: ConfigFixture.valueB, scope: .environment(staging))
        try harness.add(repo, "API_STRIPE_MODE", kind: .variable, value: "test")
        let old = try harness.add(repo, "STRIPE_OLD", value: ConfigFixture.valueC)
        try harness.markSynced(repo)
        try harness.config.deleteItems([old], repositoryID: repo.id)

        let folders = FolderRepository(session: harness.session, clock: harness.clock)
        let folder = try folders.createFolder(named: "Stripe test")
        try folders.addItem(folderID: folder, kind: .secret, name: "STRIPE_KEY", value: SecretBytes(utf8: ConfigFixture.valueA))
        let destinations = DestinationRepository(session: harness.session, clock: harness.clock)
        let vault = try destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-example-prod", tenantID: nil),
            stage: nil
        )
        try destinations.addItem(destinationID: vault, kind: .secret, name: "STRIPE_KEY", value: SecretBytes(utf8: ConfigFixture.valueA))
        let organizationKey = try await fixture.item("STRIPE_KEY")

        // A name that starts with the word first, then by name and holder; the tombstone is out.
        let matches = try harness.config.itemNames(matching: "stripe")
        #expect(matches.map(\.name) == ["STRIPE_KEY", "STRIPE_KEY", "STRIPE_KEY", "STRIPE_KEY", "STRIPE_WEBHOOK_SECRET", "API_STRIPE_MODE"])
        #expect(matches.prefix(4).map(\.holder) == [
            .place(.destination(vault)),
            .place(.folder(folder)),
            .organization(fixture.organization.id),
            .place(.scope(repositoryID: repo.id, scope: .environment(production))),
        ])
        #expect(matches[2].id == organizationKey.id)
        #expect(matches[3].id == environmentKey)
        #expect(matches.last?.kind == .variable)
        #expect(matches.last?.holder == .place(.scope(repositoryID: repo.id, scope: .repository)))

        #expect(try harness.config.itemNames(matching: "Webhook  STRIPE").map(\.name) == ["STRIPE_WEBHOOK_SECRET"])
        #expect(try harness.config.itemNames(matching: "stripe", limit: 2).count == 2)
        #expect(try harness.config.itemNames(matching: "  ").isEmpty)

        // A deleted environment's items wait for Sync, not for ⌘K.
        try harness.config.deleteEnvironment(staging)
        #expect(try harness.config.itemNames(matching: "webhook").isEmpty)
    }
}
