import Foundation
import FXVaultTestSupport
import SharingKit
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// Two vaults with **different keys** that both imported `owner-a/api`, paired as teammates
/// (v0.9.0 project shares):
///
/// | | sender | receiver |
/// |---|---|---|
/// | `FXV_S1` (repository secret) | `a1`, linked to the Key Vault copy | absent |
/// | `FXV_GH` (repository secret, same GitHub date) | `g1` | value missing |
/// | `FXV_V1` (repository variable) | `v1` | `different` (GitHub too) |
/// | `staging` | `FXV_STAGE` = `s1` | empty, on GitHub |
/// | `production` | `FXV_PROD` = `p1` | absent |
/// | Key Vault `kv-example-staging` (stage `staging`) | `FXV_S1` (linked), `FXV_KV` = `k1` | absent |
/// | Vercel `example-web` production | `NEXT_PUBLIC_URL` (public) = `https://example.test` | absent |
struct ProjectShareWorld {
    static let senderName = "Sender Mac"
    static let appVersion = "0.9.0"
    static let keyVault = DestinationTargetModel.azureKeyVault(vaultName: "kv-example-staging", tenantID: nil)
    static let vercel = DestinationTargetModel.vercel(
        projectID: "prj_sample",
        projectName: "example-web",
        teamID: nil,
        environment: .production
    )
    static let vercelToken = "vercel-token-sample-7f3a"

    let sender: SyncHarness
    let receiver: SyncHarness
    let senderSharing: SharingRepository
    let receiverSharing: SharingRepository
    let access: FakeShareRepositoryAccess
    let folder: VaultTemporaryDirectory

    static func make(paired: Bool = true) async throws -> ProjectShareWorld {
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
        let keyVault = try destinations.createDestination(repositoryID: repository.id, target: keyVault, stage: "staging", connectionID: nil)
        try destinations.copyItems([secret], to: keyVault, conflicts: .replace)
        try destinations.addItem(destinationID: keyVault, kind: .secret, name: "FXV_KV", value: SecretBytes(utf8: "k1"))
        let connection = try destinations.addConnection(
            provider: .vercel,
            label: "Sample Vercel",
            token: SecretBytes(utf8: vercelToken),
            accountHint: nil
        )
        let web = try destinations.createDestination(repositoryID: repository.id, target: vercel, stage: nil, connectionID: connection)
        let url = try destinations.addItem(
            destinationID: web,
            kind: .variable,
            name: "NEXT_PUBLIC_URL",
            value: SecretBytes(utf8: "https://example.test")
        ).itemID
        try destinations.setPublicAllowed(url, allowed: true)

        let receiverGitHub = GitHubSimulator(owner: SyncFixture.owner, name: SyncFixture.repoName)
        receiverGitHub.addVariable("FXV_V1", value: "different")
        receiverGitHub.addSecret("FXV_GH", updatedAt: ShareWorld.secretUpdatedAt)
        receiverGitHub.addEnvironment("staging", id: 42)
        let receiver = try await SyncHarness.make(github: receiverGitHub)
        try await receiver.importRepository()

        if paired {
            try pair(sender, with: receiver)
        }
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

    /// Stores each vault's card in the other one (what Add Teammate does).
    static func pair(_ left: SyncHarness, with right: SyncHarness) throws {
        let leftTeam = TeamRepository(session: left.session, clock: left.clock)
        let rightTeam = TeamRepository(session: right.session, clock: right.clock)
        try leftTeam.addTeammate(try rightTeam.deviceKeys().card(login: "user-b", displayName: "Receiver", macName: "Receiver Mac"))
        try rightTeam.addTeammate(try leftTeam.deviceKeys().card(login: "user-a", displayName: "Sender", macName: "Sender Mac"))
    }

    var senderTeam: TeamRepository {
        TeamRepository(session: sender.session, clock: sender.clock)
    }

    var receiverTeam: TeamRepository {
        TeamRepository(session: receiver.session, clock: receiver.clock)
    }

    /// The receiver's teammate id as the sender stores it.
    func receiverID() throws -> String {
        try receiverTeam.deviceKeys().deviceID.hex
    }

    /// A single-use authorization for the sender.
    func authorization() -> ShareAuthorizationModel {
        ShareAuthorizationModel(purpose: .fileExport, session: sender.session)
    }

    /// The sender's repository-level and `staging` selection with the Key Vault destination.
    func stagingSelection() async throws -> ShareBundleSelectionModel {
        try await senderSharing.selection(repositoryIDs: [sender.repository().id], stages: ["staging"])
    }

    /// Exports `selection` and returns the file and, for a passphrase file, the passphrase text.
    func export(
        _ selection: ShareBundleSelectionModel,
        protection: ShareBundleProtectionModel,
        name: String = "project.fxvault"
    ) async throws -> (url: URL, passphrase: String?, result: ShareBundleExportResultModel) {
        let result = try await senderSharing.exportBundle(
            selection,
            protection: protection,
            to: folder.url.appendingPathComponent(name),
            senderName: Self.senderName,
            appVersion: Self.appVersion,
            authorization: authorization()
        )
        let passphrase = try result.passphrase.map { try #require($0.utf8String()) }
        result.passphrase?.wipe()
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
        let exported = try await world.export(try await world.stagingSelection(), protection: .passphrase)
        let passphrase = try #require(exported.passphrase)
        #expect(!exported.result.preview.includesProduction)
        #expect(exported.result.sentShare.mode == .passphrase)
        #expect(exported.result.sentShare.recipientIDs.isEmpty)

        let inspected = try world.receiverSharing.inspectFile(at: exported.url)
        #expect(inspected.needsPassphrase)
        let (draft, sender) = try await world.openBundle(exported.url, passphrase: passphrase)
        defer { draft.discard() }
        #expect(sender == ShareFileSenderModel(displayName: ProjectShareWorld.senderName, isVerified: false))
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

    @Test func aTeammatesFileOpensOnlyForTheTeammateAndShowsAVerifiedSender() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let exported = try await world.export(try await world.stagingSelection(), protection: .teammates([try world.receiverID()]))
        #expect(exported.passphrase == nil)
        #expect(exported.result.sentShare.mode == .teammates)
        #expect(exported.result.sentShare.recipientIDs == [try world.receiverID()])

        let inspected = try world.receiverSharing.inspectFile(at: exported.url)
        #expect(inspected.isForTeammates)
        #expect(inspected.recipientCount == 1)
        let (draft, sender) = try await world.openBundle(exported.url)
        defer { draft.discard() }
        let senderID = try world.senderTeam.deviceKeys().deviceID.hex
        #expect(sender == ShareFileSenderModel(displayName: "Sender", isVerified: true, teammateID: senderID))
        #expect(draft.sender.isVerified)
        #expect(draft.manifest.repositories.first?.destinations.count == 1)
    }

    @Test func aProductionStageRefusesAPassphraseBeforeTheAuthorizationIsUsed() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let repository = try world.sender.repository()
        let selection = try await world.senderSharing.selection(repositoryIDs: [repository.id], stages: ["production"])
        let preview = try await world.senderSharing.previewBundle(selection)
        #expect(preview.productionPlaces == ["owner-a/api · production"])
        let authorization = world.authorization()
        await #expect(throws: SharingError.productionNeedsTeammates) {
            _ = try await world.senderSharing.exportBundle(
                selection,
                protection: .passphrase,
                to: world.folder.url.appendingPathComponent("production.fxvault"),
                senderName: ProjectShareWorld.senderName,
                appVersion: ProjectShareWorld.appVersion,
                authorization: authorization
            )
        }
        // The refusal left the authorization unused: the same one seals it for the teammate.
        let result = try await world.senderSharing.exportBundle(
            selection,
            protection: .teammates([try world.receiverID()]),
            to: world.folder.url.appendingPathComponent("production.fxvault"),
            senderName: ProjectShareWorld.senderName,
            appVersion: ProjectShareWorld.appVersion,
            authorization: authorization
        )
        #expect(result.preview.includesProduction)
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
    }

    @Test func aVercelProductionDestinationWithoutAStageCountsAsProduction() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let repository = try world.sender.repository()
        let web = try DestinationRepository(session: world.sender.session).destinations(repositoryID: repository.id)
            .first { $0.target == ProjectShareWorld.vercel }
        let selection = ShareBundleSelectionModel(repositories: [
            ShareBundleRepositorySelectionModel(repositoryID: repository.id, includesRepositoryLevel: false, destinationIDs: [try #require(web).id]),
        ])
        let preview = try await world.senderSharing.previewBundle(selection)
        #expect(preview.productionPlaces == ["owner-a/api · Vercel example-web (production)"])
    }

    @Test func linkedCopiesShareAFreshTokenAndPublicNamesTravel() async throws {
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
        let web = try #require(entry.destinations.first { $0.target == ProjectShareWorld.vercel })
        #expect(web.publicNames == ["NEXT_PUBLIC_URL"])
        #expect(web.variables.map(\.name) == ["NEXT_PUBLIC_URL"])

        // Only one member selected: no token.
        let alone = ShareBundleSelectionModel(repositories: [
            ShareBundleRepositorySelectionModel(repositoryID: repository.id),
        ])
        let single = try ProjectShareExportBuilder(session: world.sender.session, clock: world.sender.clock)
            .build(alone, senderName: "", appVersion: "0", includeValues: false)
        #expect(single.bundle.repositories.first?.repository.secrets.allSatisfy { $0.linkToken == nil } == true)
    }

    @Test func connectionTokensNeverEnterABundle() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let repository = try world.sender.repository()
        let destinations = try DestinationRepository(session: world.sender.session).destinations(repositoryID: repository.id)
        var selection = try await world.stagingSelection()
        selection.repositories[0].destinationIDs = Set(destinations.map(\.id))
        let built = try ProjectShareExportBuilder(session: world.sender.session, clock: world.sender.clock)
            .build(selection, senderName: ProjectShareWorld.senderName, appVersion: "0", includeValues: true)
        defer { built.bundle.wipeValues() }
        let json = try ShareBundleCoder.encode(built.bundle)
        defer { json.wipe() }
        let text = try #require(json.utf8String())
        #expect(text.contains("https://example.test"))
        #expect(!text.contains(ProjectShareWorld.vercelToken))
        #expect(!text.contains("Sample Vercel"))
        for connection in try DestinationRepository(session: world.sender.session).connections() {
            #expect(!text.contains(connection.id.uuidString))
        }
    }

    @Test func theSentLogKeepsNamesOnly() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let exported = try await world.export(try await world.stagingSelection(), protection: .teammates([try world.receiverID()]))
        let log = try await world.senderSharing.sentShares()
        #expect(log.map(\.id) == [exported.result.sentShare.id])
        #expect(log.first?.packageID == exported.result.sentShare.packageID)
        #expect(log.first?.recipientIDs == [try world.receiverID()])
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

    @Test func recipientsMustBeOneToTenPairedTeammates() async throws {
        let world = try await ProjectShareWorld.make()
        defer { world.folder.remove() }
        let selection = try await world.stagingSelection()
        let receiverID = try world.receiverID()
        for protection in [
            ShareBundleProtectionModel.teammates([]),
            .teammates([receiverID, receiverID]),
            .teammates([String(repeating: "a", count: 32)]),
            .teammates(Array(repeating: receiverID, count: Limits.maxShareRecipients + 1)),
        ] {
            await #expect(throws: SharingError.invalidRecipients) {
                _ = try await world.export(selection, protection: protection)
            }
        }
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
