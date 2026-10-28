import Foundation
import FXVaultTestSupport
import SharingKit
import Testing
import VaultCore
@_spi(Testing) @testable import VaultData
import VaultStore

@Suite("Project share import (v0.9.0)")
struct ProjectShareImportTests {
    // MARK: - Helpers

    private static func item(_ name: String, _ value: String?, token: String? = nil) -> ShareItemModel {
        ShareItemModel(
            name: name,
            value: value.map { SecretBytes(utf8: $0) },
            valueState: value == nil ? .missing : .present,
            githubUpdatedAt: nil,
            syncState: .pending,
            linkToken: token
        )
    }

    private static func bundle(
        _ world: ProjectShareWorld,
        createdAt: Date? = nil,
        stages: [String] = [],
        repositories: [ShareBundleRepositoryModel] = [],
        folders: [ShareBundleFolderModel] = []
    ) -> ShareBundleModel {
        ShareBundleModel(
            createdAt: createdAt ?? world.receiver.clock.now,
            expiry: .sevenDays,
            producer: ShareProducerModel(version: ProjectShareWorld.appVersion),
            sender: ShareSenderModel(displayName: "Other Mac"),
            stages: stages,
            repositories: repositories,
            folders: folders
        )
    }

    /// `owner-a/api` as the receiver has it (same GitHub node id), with `secrets` at repository
    /// level and `destinations`.
    private static func api(
        _ world: ProjectShareWorld,
        secrets: [ShareItemModel] = [],
        destinations: [ShareDestinationModel] = []
    ) throws -> ShareBundleRepositoryModel {
        ShareBundleRepositoryModel(
            repository: ShareRepositoryModel(
                owner: SyncFixture.owner,
                name: SyncFixture.repoName,
                githubRepoID: try world.receiver.repository().githubID,
                secrets: secrets
            ),
            destinations: destinations
        )
    }

    private static func open(_ world: ProjectShareWorld, _ bundle: ShareBundleModel, name: String = "bundle.fxvault") async throws -> ShareBundleDraftModel {
        let passphrase = try ProjectShareWorld.passphrase()
        let url = try await world.write(bundle, passphrase: passphrase, name: name)
        return try await world.openBundle(url, passphrase: passphrase).0
    }

    private static func heldNames(_ world: ProjectShareWorld, packageID: SharePackageID) throws -> [String] {
        let config = try ConfigStore(database: world.receiver.database).fetchHeldItemStates(packageID: packageID).map(\.name)
        let destinations = try DestinationStore(database: world.receiver.database).fetchHeldItemStates(packageID: packageID).map(\.name)
        return (config + destinations).sorted()
    }

    private static func destinationItems(_ world: ProjectShareWorld, target: DestinationTargetModel) throws -> [DestinationItemModel] {
        let repository = DestinationRepository(session: world.receiver.session)
        let destination = try #require(try repository.destinations(repositoryID: try world.receiver.repository().id).first { $0.target == target })
        return try repository.items(destinationID: destination.id)
    }

    // MARK: - Repositories ✓ ⇣ ✕

    @Test func repositoriesInTheVaultImportableAndOutOfReachArePlannedApart() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        world.access.makeVisible("owner-a/web")
        let web = ShareBundleRepositoryModel(
            repository: ShareRepositoryModel(
                owner: SyncFixture.owner,
                name: "web",
                githubRepoID: "R_web",
                variables: [Self.item("FXV_WEB", "w1")]
            ),
            destinations: [ShareDestinationModel(target: ProjectShareWorld.webVault, stage: nil, secrets: [Self.item("FXV_URL", "u1")])]
        )
        let hidden = ShareBundleRepositoryModel(repository: ShareRepositoryModel(
            owner: SyncFixture.owner,
            name: "hidden",
            githubRepoID: "R_hidden",
            secrets: [Self.item("FXV_HIDDEN", "h1")]
        ))
        let bundle = Self.bundle(world, stages: ["staging"], repositories: [try Self.api(world, secrets: [Self.item("FXV_NEW", "n1")]), web, hidden])
        let draft = try await Self.open(world, bundle)
        #expect(draft.plan.repositories.map(\.status) == [
            .inVault,
            .willImportFromGitHub(accountLogin: SyncFixture.login),
            .noAccess(.notVisible),
        ])
        #expect(draft.plan.repositories[1].destinations.map(\.action) == [.create])

        let imported = try await world.receiverSharing.importMissingRepositories(of: draft)
        #expect(imported.failedRepositories.isEmpty)
        #expect(world.access.imported == ["owner-a/web"])
        #expect(draft.isClosedForApply)
        let fresh = imported.draft
        #expect(fresh.plan.repositories.map(\.status) == [.inVault, .inVault, .noAccess(.notVisible)])

        let result = try await world.receiverSharing.applyBundle(fresh, plan: fresh.plan, confirmReplay: false)
        #expect(result.repositories.count == 2)
        #expect(result.firstRepositoryID == (try world.receiver.repository().id))
        #expect(result.firstStage == "staging")
        #expect(result.destinationsCreated == ["Azure Key Vault kv-example-web"])
        let webID = try #require(try RepoStore(database: world.receiver.database).fetch(ownerLogin: "owner-a", name: "web")).id
        let webItems = try world.receiver.store.fetchItemStates(repositoryID: webID).map(\.name)
        #expect(webItems == ["FXV_WEB"])
        #expect(try RepoStore(database: world.receiver.database).fetch(ownerLogin: "owner-a", name: "hidden") == nil)
        #expect(try Self.heldNames(world, packageID: bundle.packageID) == ["FXV_NEW", "FXV_URL", "FXV_WEB"])
        let record = try #require(try SharePackageStore(database: world.receiver.database).fetchAll().first)
        #expect(record.senderDeviceID == nil)
        #expect(record.senderName == "Other Mac")
        #expect(result.heldCount == 3)
        let created = try DestinationRepository(session: world.receiver.session).destinations(repositoryID: webID)
        #expect(created.map(\.target) == [ProjectShareWorld.webVault])
    }

    // MARK: - GitHub holds and links

    @Test func holdsLandExactlyOnRowsTheRemoteDoesNotHaveAndLinksAreRecreated() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let exported = try await world.export(try await world.stagingSelection())
        let (draft, _) = try await world.openBundle(exported.url, passphrase: exported.passphrase, checkGitHub: true)
        var plan = draft.plan
        let github = try #require(plan.repositories.first?.githubPlan)
        let v1 = try #require(github.item("FXV_V1"))
        #expect(v1.chip == .differs)
        #expect(v1.action == .keepMine)
        try plan.select(.overwrite, forItem: v1.id)
        let result = try await world.receiverSharing.applyBundle(draft, plan: plan, confirmReplay: false)

        let packageID = exported.result.sentShare.packageID
        #expect(try Self.heldNames(world, packageID: packageID) == ["FXV_KV", "FXV_S1", "FXV_S1", "FXV_STAGE", "FXV_V1"])
        #expect(result.heldCount == 5)
        #expect(result.linkGroupCount == 1)
        let repositoryCopy = try world.receiver.record(try #require(try world.receiver.item("FXV_S1", kind: .secret)).id)
        let keyVaultCopy = try #require(try Self.destinationItems(world, target: ProjectShareWorld.keyVault).first { $0.name == "FXV_S1" })
        let linkID = try #require(repositoryCopy.linkID)
        #expect(keyVaultCopy.linkID == linkID)
        #expect(try world.receiver.value(repositoryCopy.id) == "a1")
        #expect(repositoryCopy.provenance == .share)
        #expect(repositoryCopy.shareHold == packageID)
        // A passphrase file records the name it claims, and no sender device.
        let record = try #require(try SharePackageStore(database: world.receiver.database).fetchAll().first { $0.packageID == packageID })
        #expect(record.senderDeviceID == nil)
        #expect(record.senderName == ProjectShareWorld.senderName)
        // The overwritten variable is held too; a fill GitHub already has (same date) is not.
        #expect(try world.receiver.record(try #require(v1.localItemID)).shareHold == packageID)
        let filled = try #require(try world.receiver.item("FXV_GH", kind: .secret)).id
        #expect(try world.receiver.value(filled) == "g1")
        #expect(try world.receiver.record(filled).shareHold == nil)
    }

    // MARK: - Destinations

    @Test func destinationsMergeByTargetOrAreCreated() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let repositoryID = try world.receiver.repository().id
        let destinations = DestinationRepository(session: world.receiver.session, clock: world.receiver.clock)
        let keyVault = try destinations.createDestination(repositoryID: repositoryID, target: ProjectShareWorld.keyVault, stage: "staging")
        try destinations.addItem(destinationID: keyVault, kind: .secret, name: "FXV_KV", value: SecretBytes(utf8: "old"))
        try destinations.addItem(destinationID: keyVault, kind: .secret, name: "FXV_SAME", value: SecretBytes(utf8: "same"))
        let bundle = Self.bundle(world, repositories: [try Self.api(world, destinations: [
            ShareDestinationModel(
                target: ProjectShareWorld.keyVault,
                stage: "staging",
                secrets: [Self.item("FXV_KV", "k1"), Self.item("FXV_SAME", "same"), Self.item("FXV_ADD", "a")]
            ),
            ShareDestinationModel(
                target: ProjectShareWorld.webVault,
                stage: nil,
                secrets: [Self.item("FXV_URL", "u1"), Self.item("FXV_PLAIN", "p")]
            ),
        ])])
        let draft = try await Self.open(world, bundle)
        var plan = draft.plan
        let merged = try #require(plan.repositories.first?.destinations.first)
        #expect(merged.action == .useExisting(keyVault))
        #expect(merged.items.map(\.chip) == [.differs, .same, .new])
        try plan.select(.overwrite, forItem: merged.items[0].id)
        #expect(plan.repositories.first?.destinations.last?.action == .create)

        let result = try await world.receiverSharing.applyBundle(draft, plan: plan, confirmReplay: false)
        #expect(result.destinationsCreated == ["Azure Key Vault kv-example-web"])
        #expect(result.destinationItemsWritten == 4)
        let keyVaultItems = try Self.destinationItems(world, target: ProjectShareWorld.keyVault)
        let kv = try #require(keyVaultItems.first { $0.name == "FXV_KV" })
        #expect(try String(decoding: destinations.reveal(kv.id).withUnsafeBytes { Data($0) }, as: UTF8.self) == "k1")
        #expect(keyVaultItems.map(\.name).sorted() == ["FXV_ADD", "FXV_KV", "FXV_SAME"])
        #expect(try Self.destinationItems(world, target: ProjectShareWorld.webVault).map(\.name).sorted() == ["FXV_PLAIN", "FXV_URL"])
        #expect(try Self.heldNames(world, packageID: bundle.packageID) == ["FXV_ADD", "FXV_KV", "FXV_PLAIN", "FXV_URL"])
    }

    // MARK: - Folders

    @Test func foldersAreCreatedOrMergedAndLinkToRepositoryRows() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let folders = FolderRepository(session: world.receiver.session, clock: world.receiver.clock)
        let shared = try folders.createFolder(named: "Shared Keys")
        try folders.addItem(folderID: shared, kind: .secret, name: "API_KEY", value: SecretBytes(utf8: "mine"))
        let token = UUID().uuidString.lowercased()
        let bundle = Self.bundle(
            world,
            repositories: [try Self.api(world, secrets: [Self.item("FXV_LINKED", "l1", token: token)])],
            folders: [
                ShareBundleFolderModel(name: "Mobile App", secrets: [Self.item("FXV_LINKED", "l1", token: token)]),
                ShareBundleFolderModel(name: "shared keys", secrets: [Self.item("API_KEY", "theirs"), Self.item("NEW_KEY", "n")]),
            ]
        )
        let draft = try await Self.open(world, bundle)
        #expect(draft.plan.folders.map(\.action) == [.createNew(name: "Mobile App"), .mergeInto(shared, conflicts: .keepMine)])
        let result = try await world.receiverSharing.applyBundle(draft, plan: draft.plan, confirmReplay: false)
        #expect(result.folders == ["Mobile App", "shared keys"])
        #expect(result.linkGroupCount == 1)

        let sharedItems = try folders.items(folderID: shared)
        #expect(sharedItems.map(\.name).sorted() == ["API_KEY", "NEW_KEY"])
        let apiKey = try #require(sharedItems.first { $0.name == "API_KEY" })
        #expect(try folders.reveal(apiKey.id).utf8String() == "mine")
        let mobile = try #require(try folders.folders().first { $0.name == "Mobile App" })
        let folderCopy = try #require(try folders.items(folderID: mobile.id).first)
        let repositoryCopy = try world.receiver.record(try #require(try world.receiver.item("FXV_LINKED", kind: .secret)).id)
        #expect(folderCopy.linkID != nil)
        #expect(folderCopy.linkID == repositoryCopy.linkID)
        // Folder rows never sync, so only the repository row is held.
        #expect(try Self.heldNames(world, packageID: bundle.packageID) == ["FXV_LINKED"])
    }

    @Test func aReceivedFolderNeverMergesIntoASubfolderOfTheSameName() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let folders = FolderRepository(session: world.receiver.session, clock: world.receiver.clock)
        let backend = try folders.createFolder(named: "Backend")
        let development = try folders.createFolder(named: "Development", in: backend)
        let bundle = Self.bundle(world, folders: [ShareBundleFolderModel(name: "development", secrets: [Self.item("API_KEY", "theirs")])])

        let draft = try await Self.open(world, bundle)
        #expect(draft.plan.folders.map(\.action) == [.createNew(name: "development")])
        _ = try await world.receiverSharing.applyBundle(draft, plan: draft.plan, confirmReplay: false)

        let received = try #require(try folders.folders().first { $0.parentID == nil && $0.name == "development" })
        #expect(try folders.items(folderID: received.id).map(\.name) == ["API_KEY"])
        #expect(try folders.items(folderID: development).isEmpty)
    }

    // MARK: - Refusals

    @Test func anExpiredFileIsRefused() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let eightDaysAgo = world.receiver.clock.now.addingTimeInterval(-8 * 86_400)
        let bundle = Self.bundle(world, createdAt: eightDaysAgo, repositories: [try Self.api(world, secrets: [Self.item("FXV_OLD", "o")])])
        await #expect(throws: SharingError.share(.expired)) {
            _ = try await Self.open(world, bundle)
        }
    }

    @Test func aWrongPassphraseIsAWrongPassphrase() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let exported = try await world.export(try await world.stagingSelection())
        await #expect(throws: SharingError.share(.invalidFile)) {
            _ = try await world.openBundle(exported.url, passphrase: try ProjectShareWorld.passphrase())
        }
    }

    // MARK: - Older files, replay, outdated previews

    @Test func aFormatOneFileStillOpensAndImportsAsBefore() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let old = try await world.senderSharing.exportLegacyFile(
            .repository(try world.sender.repository().id),
            to: world.folder.url.appendingPathComponent("old.fxvault"),
            senderName: ProjectShareWorld.senderName,
            appVersion: "0.8.0",
            authorization: world.authorization()
        )
        let passphrase = try #require(old.passphrase.utf8String())
        old.passphrase.wipe()
        let inspected = try world.receiverSharing.inspectFile(at: old.fileURL)
        guard case .v1 = inspected.info else {
            Issue.record("Expected a format 1 file")
            return
        }
        let opened = try await world.receiverSharing.openShareFile(inspected, passphrase: passphrase, checkGitHub: false)
        guard case .repository(let draft) = opened.document else {
            Issue.record("Expected a repository package")
            return
        }
        let result = try await world.receiverSharing.apply(draft, plan: draft.plan, confirmReplay: false)
        #expect(result.added.contains("FXV_S1"))
        #expect(try world.receiver.record(try #require(try world.receiver.item("FXV_S1", kind: .secret)).id).shareHold == nil)
    }

    @Test func aReplayedBundleNeedsConfirmation() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let exported = try await world.export(try await world.stagingSelection())
        let (first, _) = try await world.openBundle(exported.url, passphrase: exported.passphrase)
        try await world.receiverSharing.applyBundle(first, plan: first.plan, confirmReplay: false)
        let (replay, _) = try await world.openBundle(exported.url, passphrase: exported.passphrase)
        #expect(replay.plan.replayWarnings.contains(.alreadyImported))
        await #expect(throws: SharingError.replayNotConfirmed) {
            _ = try await world.receiverSharing.applyBundle(replay, plan: replay.plan, confirmReplay: false)
        }
        let result = try await world.receiverSharing.applyBundle(replay, plan: replay.plan, confirmReplay: true)
        #expect(result.changedCount == 0)
        await #expect(throws: SharingError.draftClosed) {
            _ = try await world.receiverSharing.applyBundle(replay, plan: replay.plan, confirmReplay: true)
        }
    }

    @Test func aVaultChangedSinceThePreviewRefusesAsOutdated() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let exported = try await world.export(try await world.stagingSelection())
        let (draft, _) = try await world.openBundle(exported.url, passphrase: exported.passphrase)
        try world.receiver.add("FXV_S1", kind: .secret, value: "local")
        await #expect(throws: SharingError.planOutdated) {
            _ = try await world.receiverSharing.applyBundle(draft, plan: draft.plan, confirmReplay: false)
        }
        let fresh = try await world.receiverSharing.replanBundle(draft, checkGitHub: false)
        #expect(draft.isClosedForApply)
        #expect(fresh.plan.repositories.first?.githubPlan?.item("FXV_S1")?.chip == .differs)
    }
}
