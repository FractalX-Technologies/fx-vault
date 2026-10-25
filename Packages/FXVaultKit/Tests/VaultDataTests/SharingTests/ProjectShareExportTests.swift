import Foundation
import FXVaultTestSupport
import SharingKit
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// Two vaults with **different keys** that both imported `owner-a/api` (v0.9.0 project shares,
/// passphrase only since 1.0):
///
/// | | sender | receiver |
/// |---|---|---|
/// | `FXV_S1` (repository secret) | `a1`, linked to the Key Vault copy | absent |
/// | `FXV_GH` (repository secret, same GitHub date) | `g1` | value missing |
/// | `FXV_V1` (repository variable) | `v1` | `different` (GitHub too) |
/// | `staging` | `FXV_STAGE` = `s1` | empty, on GitHub |
/// | `production` | `FXV_PROD` = `p1` | absent |
/// | Key Vault `kv-example-staging` (stage `staging`) | `FXV_S1` (linked), `FXV_KV` = `k1` | absent |
/// | Key Vault `kv-example-web` (no stage) | `FXV_URL` = `https://example.test` | absent |
struct ProjectShareWorld {
    static let senderName = "Sender Mac"
    static let appVersion = "0.9.0"
    static let keyVault = DestinationTargetModel.azureKeyVault(vaultName: "kv-example-staging", tenantID: nil)
    static let webVault = DestinationTargetModel.azureKeyVault(vaultName: "kv-example-web", tenantID: nil)

    let sender: SyncHarness
    let receiver: SyncHarness
    let senderSharing: SharingRepository
    let receiverSharing: SharingRepository
    let access: FakeShareRepositoryAccess
    let folder: VaultTemporaryDirectory

    static func make() async throws -> ProjectShareWorld {
        let senderGitHub = GitHubSimulator(owner: SyncFixture.owner, name: SyncFixture.repoName)
        senderGitHub.addSecret("FXV_S1", updatedAt: ShareWorld.secretUpdatedAt)
        senderGitHub.addSecret("FXV_GH", updatedAt: ShareWorld.secretUpdatedAt)
        senderGitHub.addVariable("FXV_V1", value: "v1")
        senderGitHub.addEnvironment("staging", id: 42)
        senderGitHub.addVariable("FXV_STAGE", value: "s1", environment: "staging")
        senderGitHub.addEnvironment("production", id: 41)
        senderGitHub.addVariable("FXV_PROD", value: "p1", environment: "production")
        let sender = try await SyncHarness.make(github: senderGitHub)
        let repository = try await sender.importRepository()
        let secret = try #require(try sender.item("FXV_S1", kind: .secret)).id
        try sender.config.fillValue(secret, value: SecretBytes(utf8: "a1"), pushOnNextSync: false)
        let known = try #require(try sender.item("FXV_GH", kind: .secret)).id
        try sender.config.fillValue(known, value: SecretBytes(utf8: "g1"), pushOnNextSync: false)

        let destinations = DestinationRepository(session: sender.session, clock: sender.clock)
        let keyVault = try destinations.createDestination(repositoryID: repository.id, target: keyVault, stage: "staging")
        try destinations.copyItems([secret], to: keyVault, conflicts: .replace)
        try destinations.addItem(destinationID: keyVault, kind: .secret, name: "FXV_KV", value: SecretBytes(utf8: "k1"))
        let web = try destinations.createDestination(repositoryID: repository.id, target: webVault, stage: nil)
        try destinations.addItem(destinationID: web, kind: .secret, name: "FXV_URL", value: SecretBytes(utf8: "https://example.test"))

        let receiverGitHub = GitHubSimulator(owner: SyncFixture.owner, name: SyncFixture.repoName)
        receiverGitHub.addVariable("FXV_V1", value: "different")
        receiverGitHub.addSecret("FXV_GH", updatedAt: ShareWorld.secretUpdatedAt)
        receiverGitHub.addEnvironment("staging", id: 42)
        let receiver = try await SyncHarness.make(github: receiverGitHub)
        try await receiver.importRepository()

        let access = FakeShareRepositoryAccess(receiver: receiver)
        return ProjectShareWorld(
            sender: sender,
            receiver: receiver,
            senderSharing: SharingRepository(session: sender.session, schedulers: sender.schedulers, deriver: FastKeyDeriver(), clock: sender.clock),
            receiverSharing: SharingRepository(
                session: receiver.session,
                schedulers: receiver.schedulers,
                deriver: FastKeyDeriver(),
                clock: receiver.clock,
                repositoryAccess: access
            ),
            access: access,
            folder: try VaultTemporaryDirectory()
        )
    }

    /// A single-use authorization for the sender.
    func authorization() -> ShareAuthorizationModel {
        ShareAuthorizationModel(purpose: .fileExport, session: sender.session)
    }

    /// The sender's repository-level and `staging` selection with the Key Vault destination.
    func stagingSelection() async throws -> ShareBundleSelectionModel {
        try await senderSharing.selection(repositoryIDs: [sender.repository().id], stages: ["staging"])
    }

    /// Exports `selection` and returns the file and its passphrase text.
    func export(
        _ selection: ShareBundleSelectionModel,
        name: String = "project.fxvault"
    ) async throws -> (url: URL, passphrase: String, result: ShareBundleExportResultModel) {
        let result = try await senderSharing.exportBundle(
            selection,
            to: folder.url.appendingPathComponent(name),
            senderName: Self.senderName,
            appVersion: Self.appVersion,
            authorization: authorization()
        )
        let passphrase = try #require(result.passphrase.utf8String())
        result.passphrase.wipe()
        return (result.fileURL, passphrase, result)
    }

    /// Opens `url` on the receiver and returns the bundle draft.
    func openBundle(_ url: URL, passphrase: String? = nil, checkGitHub: Bool = false) async throws -> (ShareBundleDraftModel, ShareFileSenderModel) {
        let opened = try await receiverSharing.openShareFile(
            receiverSharing.inspectFile(at: url),
            passphrase: passphrase,
            checkGitHub: checkGitHub
        )
        guard case .bundle(let draft) = opened.document else {
            Issue.record("Expected a bundle")
            throw SharingError.unexpected
        }
        return (draft, opened.sender)
    }

    /// Seals `bundle` with `passphrase` (a valid 6-word phrase) into a file, as another Mac would.
    func write(_ bundle: ShareBundleModel, passphrase: String, name: String) async throws -> URL {
        let json = try ShareBundleCoder.encode(bundle)
        defer { json.wipe() }
        let file = try await FxVaultFileV2Codec(deriver: FastKeyDeriver()).sealWithPassphrase(
            payload: json,
            passphrase: SecretBytes(utf8: passphrase)
        )
        let url = folder.url.appendingPathComponent(name)
        try file.write(to: url)
        return url
    }

    /// A fresh valid passphrase.
    static func passphrase() throws -> String {
        let generated = try PassphraseGenerator.bundled().generate()
        defer { generated.wipe() }
        return try #require(generated.utf8String())
    }
}

/// Repositories missing from the receiver's vault: `visible` ones are importable, and importing
/// one inserts it (no GitHub round trip).
final class FakeShareRepositoryAccess: ShareRepositoryAccessChecking, @unchecked Sendable {
    private let receiver: SyncHarness
    private let lock = NSLock()
    private var visibleNames: Set<String> = []
    private(set) var imported: [String] = []

    init(receiver: SyncHarness) {
        self.receiver = receiver
    }

    func makeVisible(_ fullName: String) {
        lock.withLock { _ = visibleNames.insert(fullName) }
    }

    func access(owner: String, name: String) async -> ShareRepositoryAccess {
        lock.withLock { visibleNames.contains("\(owner)/\(name)") } ? .importable(accountLogin: SyncFixture.login) : .notVisible
    }

    func importRepository(owner: String, name: String, accountLogin: String?) async throws -> RepoID {
        guard lock.withLock({ visibleNames.contains("\(owner)/\(name)") }) else { throw SharingError.importBlocked(.repositoryNotImported) }
        let repository = RepoModel(
            accountLogin: SyncFixture.login,
            githubID: "R_\(name)",
            ownerLogin: owner,
            ownerType: .user,
            name: name,
            visibility: .private,
            hasAdmin: true,
            hasPush: true,
            origin: .imported,
            importedAt: receiver.clock.now
        )
        try RepoStore(database: receiver.database).insert(repository)
        lock.withLock { imported.append("\(owner)/\(name)") }
        return repository.id
    }
}

@Suite("Project share export (v0.9.0)")
struct ProjectShareExportTests {
    @Test func stagesAreOfferedWithProductionFlaggedAndExpandIntoTheSelection() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let repository = try world.sender.repository()
        let options = try await world.senderSharing.stageOptions(repositoryIDs: [repository.id])
        let flags = Dictionary(uniqueKeysWithValues: options.map { ($0.name, $0.isProduction) })
        #expect(flags == ["staging": false, "production": true])
        #expect(options.allSatisfy { $0.repositoryIDs == [repository.id] })

        let selection = try await world.stagingSelection()
        let part = try #require(selection.repositories.first)
        let staging = try #require(try world.sender.environment("staging"))
        #expect(part.includesRepositoryLevel)
        #expect(part.environmentIDs == [staging.id])
        let keyVault = try DestinationRepository(session: world.sender.session).destinations(repositoryID: repository.id)
            .first { $0.target == ProjectShareWorld.keyVault }
        #expect(part.destinationIDs == [try #require(keyVault).id])
        #expect(selection.stages == ["staging"])
        #expect(selection.expiry == .sevenDays)
    }

    @Test func aPassphraseFileReopensWithEveryPartAndAnUnverifiedSender() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let exported = try await world.export(try await world.stagingSelection())
        let passphrase = exported.passphrase
        #expect(!exported.result.preview.includesProduction)
        #expect(exported.result.sentShare.mode == .passphrase)
        #expect(exported.result.sentShare.recipientIDs.isEmpty)

        let (draft, sender) = try await world.openBundle(exported.url, passphrase: passphrase)
        defer { draft.discard() }
        #expect(sender == ShareFileSenderModel(displayName: ProjectShareWorld.senderName))
        let bundle = draft.manifest
        #expect(bundle.stages == ["staging"])
        let entry = try #require(bundle.repositories.first)
        #expect(entry.repository.secrets.map(\.name).sorted() == ["FXV_GH", "FXV_S1"])
        #expect(entry.repository.variables.map(\.name) == ["FXV_V1"])
        #expect(entry.repository.environments.map(\.name) == ["staging"])
        #expect(entry.repository.environments.first?.deploymentBranchPolicy != nil)
        #expect(entry.destinations.map(\.target) == [ProjectShareWorld.keyVault])
        #expect(entry.destinations.first?.stage == "staging")
        #expect(entry.destinations.first?.secrets.map(\.name).sorted() == ["FXV_KV", "FXV_S1"])
        #expect(draft.plan.repositories.first?.status == .inVault)
    }

    /// 1.0 never shares a production stage: the refusal comes before the authorization is used,
    /// so the same one still exports a selection without production.
    @Test func aProductionStageIsRefusedBeforeTheAuthorizationIsUsed() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let repository = try world.sender.repository()
        let selection = try await world.senderSharing.selection(repositoryIDs: [repository.id], stages: ["production"])
        let preview = try await world.senderSharing.previewBundle(selection)
        #expect(preview.productionPlaces == ["owner-a/api · production"])
        let authorization = world.authorization()
        let url = world.folder.url.appendingPathComponent("production.fxvault")
        await #expect(throws: SharingError.productionNotShared) {
            _ = try await world.senderSharing.exportBundle(
                selection,
                to: url,
                senderName: ProjectShareWorld.senderName,
                appVersion: ProjectShareWorld.appVersion,
                authorization: authorization
            )
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try await world.senderSharing.sentShares().isEmpty)
        let result = try await world.senderSharing.exportBundle(
            try await world.stagingSelection(),
            to: url,
            senderName: ProjectShareWorld.senderName,
            appVersion: ProjectShareWorld.appVersion,
            authorization: authorization
        )
        defer { result.passphrase.wipe() }
        #expect(!result.preview.includesProduction)
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
    }

    /// Only a stage makes a destination a production place (a Vercel production environment did,
    /// until 1.0).
    @Test func aDestinationWithoutAStageIsNotAProductionPlace() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let repository = try world.sender.repository()
        let web = try DestinationRepository(session: world.sender.session).destinations(repositoryID: repository.id)
            .first { $0.target == ProjectShareWorld.webVault }
        let selection = ShareBundleSelectionModel(repositories: [
            ShareBundleRepositorySelectionModel(repositoryID: repository.id, includesRepositoryLevel: false, destinationIDs: [try #require(web).id]),
        ])
        let preview = try await world.senderSharing.previewBundle(selection)
        #expect(preview.productionPlaces.isEmpty)
    }

    @Test func linkedCopiesShareAFreshToken() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let repository = try world.sender.repository()
        var selection = try await world.stagingSelection()
        let destinations = try DestinationRepository(session: world.sender.session).destinations(repositoryID: repository.id)
        selection.repositories[0].destinationIDs = Set(destinations.map(\.id))
        let built = try ProjectShareExportBuilder(session: world.sender.session, clock: world.sender.clock)
            .build(selection, senderName: "", appVersion: "0", includeValues: false)
        let entry = try #require(built.bundle.repositories.first)
        let repositoryToken = try #require(entry.repository.secrets.first { $0.name == "FXV_S1" }?.linkToken)
        let keyVault = try #require(entry.destinations.first { $0.target == ProjectShareWorld.keyVault })
        #expect(keyVault.secrets.first { $0.name == "FXV_S1" }?.linkToken == repositoryToken)
        #expect(keyVault.secrets.first { $0.name == "FXV_KV" }?.linkToken == nil)
        #expect(UUID(uuidString: repositoryToken) != nil)
        // The sender's own link id never leaves the vault.
        let senderRow = try #require(try world.sender.item("FXV_S1", kind: .secret))
        let linkID = try #require(try world.sender.record(senderRow.id).linkID)
        #expect(repositoryToken != linkID.uuidString)

        // Only one member selected: no token.
        let alone = ShareBundleSelectionModel(repositories: [
            ShareBundleRepositorySelectionModel(repositoryID: repository.id),
        ])
        let single = try ProjectShareExportBuilder(session: world.sender.session, clock: world.sender.clock)
            .build(alone, senderName: "", appVersion: "0", includeValues: false)
        #expect(single.bundle.repositories.first?.repository.secrets.allSatisfy { $0.linkToken == nil } == true)
    }

    @Test func theSentLogKeepsNamesOnly() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let exported = try await world.export(try await world.stagingSelection())
        let log = try await world.senderSharing.sentShares()
        #expect(log.map(\.id) == [exported.result.sentShare.id])
        #expect(log.first?.packageID == exported.result.sentShare.packageID)
        #expect(log.first?.mode == .passphrase && log.first?.recipientIDs == [])
        let summary = try #require(log.first).summary
        #expect(summary.stages == ["staging"])
        #expect(summary.places.map(\.kind) == [.repository, .environment, .destination])
        #expect(summary.places.first?.secretNames.sorted() == ["FXV_GH", "FXV_S1"])
        #expect(summary.places.last?.name == "Azure Key Vault kv-example-staging")
        let summaryText = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        for value in ["a1", "g1", "k1", "s1", "v1"] {
            #expect(!summaryText.contains("\"\(value)\""))
        }
        try await world.senderSharing.deleteSentShare(exported.result.sentShare.id)
        #expect(try await world.senderSharing.sentShares().isEmpty)
    }

    @Test func theDefaultFileNameNamesNoRepository() throws {
        let date = Date(timeIntervalSince1970: 1_792_195_200) // 2026-10-17 00:00 UTC
        let name = SharingRepository.defaultFileName(createdAt: date, timeZone: try #require(TimeZone(identifier: "UTC")))
        #expect(name == "FX Vault share 2026-10-17.fxvault")
    }

    @Test func anEmptySelectionHasNothingToShare() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        await #expect(throws: SharingError.nothingToShare) {
            _ = try await world.senderSharing.previewBundle(ShareBundleSelectionModel())
        }
    }
}
