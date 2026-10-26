import EnvTools
import Foundation
import SyncEngine
import Testing
import VaultCore
import VaultCrypto
@testable import VaultData
import VaultStore

/// Destinations (v0.8.0, tasks/todo.md R1–R3): targets and stages, provider rules for items,
/// pending state (tombstones, renames, fills), copy and links across the three item tables,
/// `.env` import and export, DEK rotation, and that no GitHub sync input ever sees a destination
/// item.
@Suite("DestinationRepository")
struct DestinationRepositoryTests {
    static let keyVault = DestinationTargetModel.azureKeyVault(vaultName: "kv-sample-prod", tenantID: nil)
    static let webVault = DestinationTargetModel.azureKeyVault(vaultName: "kv-sample-web", tenantID: nil)

    struct Fixture {
        let harness: ConfigHarness
        let destinations: DestinationRepository
        let repo: RepoModel

        static func make() async throws -> Fixture {
            let harness = try await ConfigHarness.make()
            let repo = try harness.seedRepository()
            return Fixture(harness: harness, destinations: DestinationRepository(session: harness.session, clock: harness.clock), repo: repo)
        }

        var store: DestinationStore {
            DestinationStore(database: harness.database)
        }

        func keyVault(stage: String? = "production") throws -> DestinationID {
            try destinations.createDestination(repositoryID: repo.id, target: DestinationRepositoryTests.keyVault, stage: stage)
        }

        @discardableResult
        func add(_ destination: DestinationID, _ name: String, kind: ConfigKind = .secret, value: String) throws -> ConfigItemID {
            try destinations.addItem(destinationID: destination, kind: kind, name: name, value: SecretBytes(utf8: value)).itemID
        }

        func reveal(_ id: ConfigItemID) throws -> String? {
            let value = try destinations.reveal(id)
            defer { value.wipe() }
            return value.utf8String()
        }

        func record(_ id: ConfigItemID) throws -> DestinationItemRecord {
            try #require(try store.fetchItemRecord(id: id))
        }

        func status(_ id: ConfigItemID) throws -> ConfigSyncStatus {
            try record(id).syncStatus
        }

        /// What a Sync leaves behind: every live row pushed with its current value, tombstones gone.
        func markSynced(_ destination: DestinationID) throws {
            try harness.database.write { tx in
                for var row in try store.fetchItemRecords(destinationID: destination, in: tx) {
                    if row.isDeleted {
                        try store.deleteItem(id: row.id, in: tx)
                        continue
                    }
                    row.syncedName = row.name
                    row.syncedKind = row.kind
                    row.syncedFingerprint = row.valueFingerprint
                    row.forcePush = false
                    row.remoteVersion = "1"
                    try store.updateItem(row, in: tx)
                }
            }
        }

        func names(_ destination: DestinationID) throws -> [String] {
            try destinations.items(destinationID: destination).filter { !$0.isDeleted }.map(\.name)
        }
    }

    // MARK: - Destinations (R1)

    @Test func destinationsValidateTargetsAndStages() async throws {
        let fixture = try await Fixture.make()
        let vault = try fixture.keyVault()
        #expect(configError {
            try fixture.destinations.createDestination(repositoryID: fixture.repo.id, target: Self.keyVault, stage: nil)
        } == .destinationExists)
        #expect(configError {
            try fixture.destinations.createDestination(
                repositoryID: fixture.repo.id,
                target: .azureKeyVault(vaultName: "kv--bad", tenantID: nil),
                stage: nil
            )
        } == .validation(.invalidDestinationTarget(.keyVaultName)))
        #expect(configError {
            try fixture.destinations.createDestination(repositoryID: fixture.repo.id, target: Self.webVault, stage: " bad")
        } == .validation(.invalidName(.leadingOrTrailingWhitespace)))
        #expect(configError {
            try fixture.destinations.createDestination(repositoryID: RepoID(), target: Self.webVault, stage: nil)
        } == .repositoryNotFound)

        let web = try fixture.destinations.createDestination(repositoryID: fixture.repo.id, target: Self.webVault, stage: "staging")
        try fixture.destinations.updateDestination(web, stage: "Production")
        let models = try fixture.destinations.destinations(repositoryID: fixture.repo.id)
        #expect(models.map(\.id) == [vault, web])
        #expect(models.map(\.stageKey) == ["production", "production"])

        try fixture.destinations.reorderDestinations([web, vault], repositoryID: fixture.repo.id)
        #expect(try fixture.destinations.destinations(repositoryID: fixture.repo.id).map(\.id) == [web, vault])
        try fixture.destinations.deleteDestination(web)
        #expect(configError { try fixture.destinations.deleteDestination(web) } == .destinationNotFound)
    }

    // MARK: - Key Vaults of their own (1.0, B8b)

    /// Connect Azure saves the vault's subscription (1.0 D6c6); one imported before gets it from
    /// a Refresh. The name is trimmed, and an empty one is never saved.
    @Test func aKeyVaultKeepsItsSubscription() async throws {
        let fixture = try await Fixture.make()
        let production = KeyVaultSubscriptionModel(id: UUID(), name: "Example Production")
        let imported = try fixture.destinations.createDestination(
            repositoryID: nil,
            target: Self.keyVault,
            stage: nil,
            subscription: production
        )
        let older = try fixture.destinations.createDestination(
            repositoryID: nil,
            target: .azureKeyVault(vaultName: "kv-sample-legacy", tenantID: nil),
            stage: nil
        )
        #expect(try fixture.destinations.destination(imported)?.subscription == production)
        #expect(try fixture.destinations.destination(older)?.subscription == nil)

        try fixture.destinations.setSubscription(KeyVaultSubscriptionModel(id: production.id, name: "  Example Production "), of: older)
        #expect(try fixture.destinations.destination(older)?.subscription == production)
        try fixture.destinations.setSubscription(KeyVaultSubscriptionModel(id: UUID(), name: " "), of: older)
        #expect(try fixture.destinations.destination(older)?.subscription == production)
        #expect(configError {
            try fixture.destinations.setSubscription(production, of: DestinationID())
        } == .destinationNotFound)
    }

    @Test func keyVaultsOfTheirOwnStandBesideRepositoryDestinations() async throws {
        let fixture = try await Fixture.make()
        let standalone = try fixture.destinations.createDestination(repositoryID: nil, target: Self.keyVault, stage: nil)
        #expect(configError {
            try fixture.destinations.createDestination(repositoryID: nil, target: Self.keyVault, stage: nil)
        } == .destinationExists)
        // The same vault can still serve a repository: the two rows are separate places.
        let underRepository = try fixture.keyVault()

        #expect(try fixture.destinations.destinations(repositoryID: nil).map(\.id) == [standalone])
        #expect(try fixture.destinations.destinations(repositoryID: fixture.repo.id).map(\.id) == [underRepository])
        let model = try #require(try fixture.destinations.destination(standalone))
        #expect(model.repositoryID == nil)
        #expect(model.target == Self.keyVault)

        // A copy into it is linked, and its place names no repository.
        let source = try fixture.harness.add(fixture.repo, "DATABASE_URL", value: ConfigFixture.valueA)
        #expect(try fixture.destinations.copyItems([source], to: standalone, conflicts: .keep).added == 1)
        let place = try #require(try fixture.harness.config.linkedCopies(of: source).first?.place)
        guard case .destination(let id, let repositoryID, let fullName, _, let displayName, _) = place else {
            Issue.record("expected a destination place, got \(place)")
            return
        }
        #expect(id == standalone && repositoryID == nil && fullName == nil)
        #expect(displayName == "kv-sample-prod")
        // Its pending add counts for the vaults of their own (B8c), not the repository.
        #expect(try fixture.destinations.pendingCounts() == [nil: 1])

        // Removing the repository removes its destination only.
        #expect(try RepoStore(database: fixture.harness.database).delete(id: fixture.repo.id))
        #expect(try fixture.destinations.destination(underRepository) == nil)
        #expect(try fixture.destinations.destinations(repositoryID: nil).map(\.secretCount) == [1])
    }

    // MARK: - Items (R3)

    @Test func stageSuggestionsListDestinationStagesThenEnvironmentsOnce() async throws {
        let fixture = try await Fixture.make()
        try fixture.destinations.createDestination(
            repositoryID: fixture.repo.id,
            target: .azureKeyVault(vaultName: "kv-sample-qa", tenantID: nil),
            stage: "qa"
        )
        try fixture.harness.config.createEnvironment(in: fixture.repo.id, name: "preview")
        try fixture.harness.config.createEnvironment(in: fixture.repo.id, name: "QA")

        #expect(try fixture.destinations.stageSuggestions(repositoryID: fixture.repo.id) == ["qa", "preview"])
    }

    @Test func keyVaultHoldsSecretsOnly() async throws {
        let fixture = try await Fixture.make()
        let vault = try fixture.keyVault()
        let id = try fixture.add(vault, "API_URL", kind: .variable, value: "https://api.example.invalid")
        #expect(try fixture.record(id).kind == .secret)

        #expect(configError { try fixture.add(vault, "BAD-NAME", value: "x") } == .validation(.invalidName(.invalidCharacter)))
        try fixture.add(vault, "STRIPE_SECRET_KEY", value: ConfigFixture.valueA)
        #expect(configError { try fixture.add(vault, "STRIPE_SECRET_KEY", value: ConfigFixture.valueB) } == .validation(.duplicateName))

        let tooLarge = String(repeating: "a", count: Limits.maxKeyVaultValueBytes + 1)
        #expect(configError { try fixture.add(vault, "BIG", value: tooLarge) } == .validation(.valueTooLarge(limit: Limits.maxKeyVaultValueBytes)))
    }

    @Test func pendingStateFollowsEditsDeletesAndReverts() async throws {
        let fixture = try await Fixture.make()
        let vault = try fixture.keyVault()
        let kept = try fixture.add(vault, "DATABASE_URL", value: ConfigFixture.valueA)
        let removed = try fixture.add(vault, "OLD_KEY", value: ConfigFixture.valueB)
        let renamed = try fixture.add(vault, "STRIPE_KEY", value: ConfigFixture.valueC)
        #expect(try fixture.status(kept) == .added)
        try fixture.markSynced(vault)
        #expect(try fixture.status(kept) == .synced)

        try fixture.destinations.editItem(kept, name: "DATABASE_URL", kind: .secret, value: SecretBytes(utf8: ConfigFixture.valueB))
        #expect(try fixture.status(kept) == .modified)
        // Back to the pushed value: nothing to send.
        try fixture.destinations.editItem(kept, name: "DATABASE_URL", kind: .secret, value: SecretBytes(utf8: ConfigFixture.valueA))
        #expect(try fixture.status(kept) == .synced)

        try fixture.destinations.deleteItems([removed])
        #expect(try fixture.status(removed) == .deleted)
        try fixture.destinations.revertItems([removed])
        #expect(try fixture.status(removed) == .synced)

        // A pushed item is renamed by deleting the old name and adding the new one.
        let result = try fixture.destinations.editItem(renamed, name: "STRIPE_SECRET_KEY", kind: .secret, value: nil)
        #expect(result.itemID != renamed)
        #expect(try fixture.record(renamed).isDeleted)
        #expect(try fixture.status(result.itemID) == .added)
        #expect(try fixture.reveal(result.itemID) == ConfigFixture.valueC)
        #expect(try fixture.names(vault) == ["DATABASE_URL", "OLD_KEY", "STRIPE_SECRET_KEY"])

        // Adding a name a tombstone holds revives that row.
        let revived = try fixture.add(vault, "STRIPE_KEY", value: ConfigFixture.valueA)
        #expect(revived == renamed)
        #expect(try fixture.status(revived) == .modified)

        // A never-pushed item is removed outright and a pending add can be reverted.
        let fresh = try fixture.add(vault, "FRESH_KEY", value: ConfigFixture.valueA)
        try fixture.destinations.revertItems([fresh])
        #expect(try fixture.store.fetchItemRecord(id: fresh) == nil)

        try fixture.destinations.requestPush([kept])
        #expect(try fixture.status(kept) == .willPush)
    }

    @Test func writeOnlyValuesCanBeFilledWithOrWithoutAPush() async throws {
        let fixture = try await Fixture.make()
        let vault = try fixture.keyVault()
        let pushed = try fixture.add(vault, "API_KEY", value: ConfigFixture.valueA)
        let matched = try fixture.add(vault, "OTHER_KEY", value: ConfigFixture.valueB)
        try fixture.markSynced(vault)
        // As an import of write-only values leaves them.
        try fixture.harness.database.write { tx in
            for id in [pushed, matched] {
                var row = try #require(try fixture.store.fetchItemRecord(id: id, in: tx))
                row.valueCiphertext = nil
                row.valueFingerprint = nil
                row.syncedFingerprint = nil
                try fixture.store.updateItem(row, in: tx)
            }
        }
        #expect(try fixture.status(pushed) == .synced)
        #expect(configError { _ = try fixture.destinations.reveal(pushed) } == .valueMissing)

        try fixture.destinations.fillValue(pushed, value: SecretBytes(utf8: ConfigFixture.valueC), alreadyMatchesRemote: false)
        try fixture.destinations.fillValue(matched, value: SecretBytes(utf8: ConfigFixture.valueB), alreadyMatchesRemote: true)
        #expect(try fixture.status(pushed) == .modified)
        #expect(try fixture.status(matched) == .synced)
        #expect(try fixture.reveal(matched) == ConfigFixture.valueB)
    }

    // MARK: - Copy and links

    @Test func copiesFromRepositoriesAndFoldersAreLinked() async throws {
        let fixture = try await Fixture.make()
        let vault = try fixture.keyVault()
        let source = try fixture.harness.add(fixture.repo, "DATABASE_URL", value: ConfigFixture.valueA)
        let variable = try fixture.harness.add(fixture.repo, "API_URL", kind: .variable, value: ConfigFixture.valueB)
        let folders = FolderRepository(session: fixture.harness.session, clock: fixture.harness.clock)
        let folder = try folders.createFolder(named: "Stripe live")
        let folderItem = try folders.addItem(folderID: folder, kind: .secret, name: "STRIPE_SECRET_KEY", value: SecretBytes(utf8: ConfigFixture.valueC)).itemID

        let result = try fixture.destinations.copyItems([source, variable, folderItem], to: vault, conflicts: .keep)
        #expect(result.added == 3)
        #expect(result.madeSecret == ["API_URL"])
        #expect(try fixture.names(vault) == ["API_URL", "DATABASE_URL", "STRIPE_SECRET_KEY"])
        #expect(try fixture.destinations.copyConflicts([source, folderItem], to: vault).sorted() == ["DATABASE_URL", "STRIPE_SECRET_KEY"])

        // Keep leaves the destination's value; Replace takes the source's.
        let copy = try #require(try fixture.destinations.items(destinationID: vault).first { $0.name == "DATABASE_URL" })
        try fixture.destinations.editItem(copy.id, name: "DATABASE_URL", kind: .secret, value: SecretBytes(utf8: ConfigFixture.valueC))
        #expect(try fixture.destinations.copyItems([source], to: vault, conflicts: .keep).kept == 1)
        #expect(try fixture.reveal(copy.id) == ConfigFixture.valueC)
        #expect(try fixture.destinations.copyItems([source], to: vault, conflicts: .replace).replaced == 1)
        #expect(try fixture.reveal(copy.id) == ConfigFixture.valueA)

        // The repository item lists the destination copy, and a rotation reaches it.
        let copies = try fixture.harness.config.linkedCopies(of: source)
        let place = try #require(copies.first)
        #expect(copies.count == 1)
        #expect(place.itemPlace == .destination(vault))
        #expect(place.placeName == "kv-sample-prod")
        #expect(place.comparison == .same)
        #expect(try fixture.destinations.items(destinationID: vault).first { $0.name == "DATABASE_URL" }?.linkCount == 2)

        try fixture.harness.config.editValue(source, value: SecretBytes(utf8: ConfigFixture.valueB))
        #expect(try fixture.harness.config.linkedCopies(of: source).first?.comparison == .differs)
        #expect(try fixture.harness.config.updateLinkedCopies(from: source, to: [copy.id]) == 1)
        #expect(try fixture.reveal(copy.id) == ConfigFixture.valueB)

        // A destination item can be the source of a copy too.
        let back = try fixture.harness.config.copyItems([copy.id], to: .repository, repositoryID: fixture.repo.id, conflicts: .keep)
        #expect(back.kept == 1)
        try fixture.harness.config.unlink(source)
        #expect(try fixture.destinations.items(destinationID: vault).first { $0.name == "DATABASE_URL" }?.isLinked == false)
    }

    // MARK: - .env files

    @Test func envFilesImportIntoAndExportFromADestination() async throws {
        let fixture = try await Fixture.make()
        let vault = try fixture.keyVault()
        try fixture.add(vault, "EXISTING_KEY", value: ConfigFixture.valueA)
        let directory = try ConfigTempDirectory()
        defer { directory.remove() }
        let files = EnvFileRepository(
            session: fixture.harness.session,
            gitignoreChecker: StubGitignoreChecker(),
            cloudSyncDetector: CloudSyncDetector(homeDirectory: directory.url, isUbiquitous: { _ in false }),
            clock: fixture.harness.clock
        )
        let contents = SecretBytes(utf8: "EXISTING_KEY=new\nAPI_URL=https://api.example.invalid\n")
        defer { contents.wipe() }
        let preview = try files.parse(contents)
        defer { preview.wipe() }
        let selections = preview.defaultSelections.map {
            EnvImportSelectionModel(candidateIndex: $0.candidateIndex, name: $0.name, kind: .variable, onConflict: .skip)
        }
        #expect(try files.conflictingCandidates(for: selections, in: preview, place: .destination(vault)) == [0])
        let result = try files.applyImport(preview, selections: selections, place: .destination(vault))
        #expect(result.added == ["API_URL"])
        #expect(result.skipped.map(\.reason) == [.existingItem])
        #expect(try fixture.destinations.items(destinationID: vault).first { $0.name == "API_URL" }?.kind == .secret)

        let exportPreview = try files.exportPreview(place: .destination(vault))
        #expect(exportPreview.exportedNames == ["API_URL", "EXISTING_KEY"])
        let authorization = try await ReauthGate(manager: fixture.harness.manager).authorizeEnvExport(
            with: .password(ConfigFixture.password),
            session: fixture.harness.session
        )
        let url = directory.file("runtime.env")
        try files.export(place: .destination(vault), to: url, authorization: authorization)
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("EXISTING_KEY="))
        #expect(written.contains(ConfigFixture.valueA))
        #expect(written.contains("API_URL=https://api.example.invalid"))
    }

    // MARK: - Keys and sync isolation

    @Test func dekRotationReSealsValuesAndFingerprints() async throws {
        let fixture = try await Fixture.make()
        let vault = try fixture.keyVault()
        let synced = try fixture.add(vault, "API_KEY", value: ConfigFixture.valueA)
        let changed = try fixture.add(vault, "OTHER_KEY", value: ConfigFixture.valueB)
        try fixture.markSynced(vault)
        try fixture.destinations.editItem(changed, name: "OTHER_KEY", kind: .secret, value: SecretBytes(utf8: ConfigFixture.valueC))
        let before = try fixture.record(synced)

        _ = try await fixture.harness.manager.rotateDEK(password: ConfigFixture.password)

        let after = try fixture.record(synced)
        #expect(after.valueCiphertext != before.valueCiphertext)
        #expect(after.valueFingerprint != before.valueFingerprint)
        #expect(after.syncedFingerprint == after.valueFingerprint)
        #expect(try fixture.status(synced) == .synced)
        #expect(try fixture.status(changed) == .modified)
        #expect(try fixture.reveal(synced) == ConfigFixture.valueA)
    }

    @Test func noGitHubSyncInputSeesADestinationItem() async throws {
        let fixture = try await Fixture.make()
        try fixture.harness.add(fixture.repo, "API_KEY", value: ConfigFixture.valueA)
        try fixture.harness.markSynced(fixture.repo)
        let before = try fixture.harness.changeSet(fixture.repo)
        let vault = try fixture.keyVault()
        try fixture.add(vault, "API_KEY", value: ConfigFixture.valueB)
        try fixture.add(vault, "NEW_ITEM", value: ConfigFixture.valueC)
        #expect(try fixture.harness.changeSet(fixture.repo) == before)
        #expect(try fixture.harness.states(fixture.repo).map(\.name) == ["API_KEY"])
        #expect(try fixture.destinations.pendingCounts() == [fixture.repo.id: 2])
    }
}
