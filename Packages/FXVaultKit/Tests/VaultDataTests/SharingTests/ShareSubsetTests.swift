import Foundation
import FXVaultTestSupport
import SharingKit
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// "Share any combination" (v0.2.0) end to end: `ShareSelectionModel.subset` export, the branch
/// policy rule (only for selected environments), the narrowest scope, partial-package merges,
/// and importing a `.fxvault` file written by FX Vault 0.1.1.
@Suite("Share subsets", .timeLimit(.minutes(1)))
struct ShareSubsetTests {
    /// The sender's rows of ``ShareWorld``.
    private struct SenderRows {
        let repositoryID: RepoID
        let production: EnvironmentID
        let s1: ConfigItemID
        let v1: ConfigItemID
        let s2: ConfigItemID
        let v2: ConfigItemID

        init(_ world: ShareWorld) throws {
            let sender = world.sender
            repositoryID = try sender.repository().id
            let environment = try #require(try sender.environment("production"))
            production = environment.id
            s1 = try #require(try sender.item("FXV_S1", kind: .secret)).id
            v1 = try #require(try sender.item("FXV_V1", kind: .variable)).id
            s2 = try #require(try sender.item("FXV_S2", kind: .secret, scope: .environment(environment.id))).id
            v2 = try #require(try sender.item("FXV_V2", kind: .variable, scope: .environment(environment.id))).id
        }

        func subset(environments: Set<EnvironmentID> = [], items: Set<ConfigItemID> = []) -> ShareSelectionModel {
            .subset(ShareSubsetModel(repositoryID: repositoryID, environmentIDs: environments, itemIDs: items))
        }
    }

    private func build(_ selection: ShareSelectionModel, in world: ShareWorld) throws -> SharePackageModel {
        try ShareExportBuilder(session: world.sender.session, clock: world.sender.clock)
            .build(selection, senderName: ShareWorld.senderName, appVersion: ShareWorld.appVersion, includeValues: false)
    }

    // MARK: - Export: every combination

    @Test func repositoryLevelOnly() async throws {
        let world = try await ShareWorld.make()
        let rows = try SenderRows(world)
        let package = try build(rows.subset(items: [rows.s1, rows.v1]), in: world)
        #expect(package.scope == .repository)
        #expect(package.schemaVersion == SharePackageModel.wholeEnvironmentsSchemaVersion)
        #expect(package.repository.secrets.map(\.name) == ["FXV_S1"])
        #expect(package.repository.variables.map(\.name) == ["FXV_V1"])
        #expect(package.repository.environments.isEmpty)
    }

    @Test func oneWholeEnvironmentIsTheEnvironmentScopeWithItsPolicy() async throws {
        let world = try await ShareWorld.make()
        let rows = try SenderRows(world)
        let package = try build(rows.subset(environments: [rows.production]), in: world)
        #expect(package.scope == .environment)
        #expect(package.schemaVersion == SharePackageModel.wholeEnvironmentsSchemaVersion)
        let environment = try #require(package.repository.environments.first)
        #expect(environment.deploymentBranchPolicy == ShareBranchPolicyModel(
            type: .custom,
            patterns: [ShareBranchPatternModel(name: "release/*", type: .branch)]
        ))
        #expect(environment.secrets.map(\.name) == ["FXV_S2"])
        #expect(environment.variables.map(\.name) == ["FXV_V2"])
        let direct = try build(.environment(rows.production), in: world)
        #expect(direct.scope == package.scope)
        #expect(direct.manifest().flattenedItems.map(\.item.name) == package.manifest().flattenedItems.map(\.item.name))
        #expect(direct.repository.environments.first?.deploymentBranchPolicy == environment.deploymentBranchPolicy)
    }

    @Test func repositoryLevelPlusAWholeEnvironment() async throws {
        let world = try await ShareWorld.make()
        let rows = try SenderRows(world)
        // The environment's own item listed again adds nothing.
        let package = try build(rows.subset(environments: [rows.production], items: [rows.s1, rows.s2]), in: world)
        #expect(package.scope == .repository)
        #expect(package.schemaVersion == SharePackageModel.wholeEnvironmentsSchemaVersion)
        #expect(package.repository.secrets.map(\.name) == ["FXV_S1"])
        #expect(package.repository.variables.isEmpty)
        let environment = try #require(package.repository.environments.first)
        #expect(environment.includesBranchPolicy)
        #expect(environment.secrets.map(\.name) == ["FXV_S2"])
        #expect(environment.variables.map(\.name) == ["FXV_V2"])
    }

    @Test func individualItemsMakePartialEnvironmentsWithoutPolicy() async throws {
        let world = try await ShareWorld.make()
        let rows = try SenderRows(world)
        let package = try build(rows.subset(items: [rows.v1, rows.v2]), in: world)
        #expect(package.scope == .repository)
        #expect(package.schemaVersion == SharePackageModel.partialEnvironmentsSchemaVersion)
        #expect(package.repository.variables.map(\.name) == ["FXV_V1"])
        let environment = try #require(package.repository.environments.first)
        #expect(environment.name == "production")
        #expect(environment.deploymentBranchPolicy == nil)
        #expect(environment.secrets.isEmpty)
        #expect(environment.variables.map(\.name) == ["FXV_V2"])
    }

    @Test func aSingleEnvironmentItemIsTheSecretScopeWithoutPolicy() async throws {
        let world = try await ShareWorld.make()
        let rows = try SenderRows(world)
        for selection in [ShareSelectionModel.item(rows.s2), rows.subset(items: [rows.s2])] {
            let package = try build(selection, in: world)
            #expect(package.scope == .secret)
            #expect(package.schemaVersion == SharePackageModel.partialEnvironmentsSchemaVersion)
            #expect(package.repository.environments.first?.includesBranchPolicy == false)
            #expect(package.itemCount == 1)
        }
        let repositoryItem = try build(rows.subset(items: [rows.s1]), in: world)
        #expect(repositoryItem.scope == .secret)
        #expect(repositoryItem.schemaVersion == SharePackageModel.wholeEnvironmentsSchemaVersion)
    }

    @Test func previewCountsPerScopeAndNeverValues() async throws {
        let world = try await ShareWorld.make()
        let rows = try SenderRows(world)
        let preview = try await world.senderSharing.previewExport(rows.subset(items: [rows.s1, rows.v1, rows.v2]))
        #expect(preview.scope == .repository)
        #expect(preview.itemCount == 3)
        #expect(preview.summary.repositoryLevel == ShareItemCountModel(secrets: 1, variables: 1))
        #expect(preview.summary.environments == [
            ShareEnvironmentSummaryModel(name: "production", counts: ShareItemCountModel(secrets: 0, variables: 1), includesBranchPolicy: false),
        ])
        let description = String(describing: preview)
        for value in ["a1", "v1", "p2"] {
            #expect(!description.contains("\"\(value)\""))
        }
    }

    @Test func invalidSubsetsAreRejected() async throws {
        let world = try await ShareWorld.make()
        let rows = try SenderRows(world)
        await #expect(throws: SharingError.nothingToShare) {
            _ = try await world.senderSharing.previewExport(rows.subset())
        }
        await #expect(throws: SharingError.itemNotFound) {
            _ = try await world.senderSharing.previewExport(rows.subset(items: [ConfigItemID()]))
        }
        await #expect(throws: SharingError.environmentNotFound) {
            _ = try await world.senderSharing.previewExport(rows.subset(environments: [EnvironmentID()]))
        }
        await #expect(throws: SharingError.repositoryNotFound) {
            _ = try await world.senderSharing.previewExport(.subset(ShareSubsetModel(repositoryID: RepoID(), itemIDs: [rows.s1])))
        }
    }

    // MARK: - File round trips and partial merges

    @Test func repositoryLevelPlusOneEnvironmentFileRoundTrip() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let rows = try SenderRows(world)
        let (file, passphrase) = try await world.export(rows.subset(environments: [rows.production], items: [rows.s1]))
        let draft = try await world.open(file, passphrase: passphrase)
        #expect(draft.manifest.schemaVersion == SharePackageModel.wholeEnvironmentsSchemaVersion)
        #expect(draft.plan.item("FXV_S1")?.chip == .new)
        #expect(draft.plan.item("FXV_V1") == nil)
        let production = try #require(draft.plan.environments.first)
        #expect(production.includesBranchPolicy)
        #expect(production.policyDifference?.decision == .keepMine)

        var plan = draft.plan
        try plan.setPolicyDecision(.useIncoming, forEnvironment: production.id)
        let result = try await world.receiverSharing.apply(draft, plan: plan, confirmReplay: false)
        #expect(result.added.sorted() == ["FXV_S1", "production/FXV_V2"])
        #expect(result.filled == ["production/FXV_S2"])
        #expect(result.policiesChanged == ["production"])
        let environment = try #require(try world.receiver.environment("production"))
        #expect(environment.branchPolicy.kind == .custom)
        #expect(Self.patterns(environment) == ["release/*|branch"])
        // Not in the package: untouched.
        let v1 = try #require(try world.receiver.item("FXV_V1", kind: .variable))
        #expect(try world.receiver.value(v1.id) == "different")
    }

    @Test func itemsOnlyMergeLeavesTheReceiversPolicyAlone() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let rows = try SenderRows(world)
        let (file, passphrase) = try await world.export(rows.subset(items: [rows.s1, rows.v2]))
        let draft = try await world.open(file, passphrase: passphrase)
        #expect(draft.manifest.schemaVersion == SharePackageModel.partialEnvironmentsSchemaVersion)
        let production = try #require(draft.plan.environments.first)
        #expect(production.action == .useExisting)
        #expect(!production.includesBranchPolicy)
        #expect(production.policyDifference == nil)
        #expect(draft.plan.allItems.map(\.key.name).sorted() == ["FXV_S1", "FXV_V2"])

        let result = try await world.receiverSharing.apply(draft, plan: draft.plan, confirmReplay: false)
        #expect(result.added.sorted() == ["FXV_S1", "production/FXV_V2"])
        #expect(result.filled.isEmpty)
        #expect(result.policiesChanged.isEmpty)
        #expect(result.environmentsCreated.isEmpty)
        let environment = try #require(try world.receiver.environment("production"))
        #expect(environment.branchPolicy == .all)
        // FXV_S2 was not shared: still value-missing on the receiver.
        let s2 = try #require(try world.receiver.item("FXV_S2", kind: .secret, scope: .environment(environment.id)))
        #expect(try world.receiver.value(s2.id) == nil)
        #expect(try world.receiver.pendingCount() == 2)
    }

    @Test func aMissingPartialEnvironmentIsCreatedWithAllBranchesWhenGitHubIsUnknown() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let (rows, stagingItem) = try addSenderStaging(world)
        let (file, passphrase) = try await world.export(rows.subset(items: [stagingItem]))
        let draft = try await world.open(file, passphrase: passphrase, checkGitHub: false)
        let staging = try #require(draft.plan.environments.first)
        #expect(staging.action == .create(pending: true))
        #expect(staging.incomingPolicy == nil)

        let result = try await world.receiverSharing.apply(draft, plan: draft.plan, confirmReplay: false)
        #expect(result.environmentsCreated == ["staging"])
        let environment = try #require(try world.receiver.environment("staging"))
        #expect(environment.branchPolicy == .all)
        #expect(!environment.isSynced)
    }

    @Test func aMissingPartialEnvironmentTakesGitHubsPolicyWhenGitHubListsIt() async throws {
        let receiverGitHub = GitHubSimulator(owner: SyncFixture.owner, name: SyncFixture.repoName)
        let world = try await ShareWorld.make(receiverGitHub: receiverGitHub)
        defer { world.folder.remove() }
        // GitHub gets "staging" after the receiver imported the repository.
        receiverGitHub.addEnvironment("staging", id: 77, policy: .custom, patterns: [("main", .branch), ("v*", .tag)])
        let (rows, stagingItem) = try addSenderStaging(world)
        let (file, passphrase) = try await world.export(rows.subset(items: [stagingItem]))
        let draft = try await world.open(file, passphrase: passphrase, checkGitHub: true)
        let staging = try #require(draft.plan.environments.first)
        #expect(staging.action == .create(pending: false))

        let pendingBefore = try world.receiver.pendingCount()
        let result = try await world.receiverSharing.apply(draft, plan: draft.plan, confirmReplay: false)
        #expect(result.environmentsCreated == ["staging"])
        let environment = try #require(try world.receiver.environment("staging"))
        #expect(environment.isSynced)
        #expect(environment.githubEnvID == 77)
        #expect(environment.syncedBranchPolicy == .custom)
        #expect(!environment.hasPendingPolicyChange)
        #expect(environment.branchPolicy.kind == .custom)
        #expect(Self.patterns(environment) == ["main|branch", "v*|tag"])
        let patternsSynced = environment.branchPolicy.patterns.allSatisfy { $0.isSynced }
        #expect(patternsSynced)
        // Only the shared item is pending; the environment and its policy are not.
        #expect(try world.receiver.pendingCount() == pendingBefore + 1)
    }

    @Test func aMissingPartialEnvironmentWithEveryItemSkippedIsNotCreated() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let (rows, stagingItem) = try addSenderStaging(world)
        let (file, passphrase) = try await world.export(rows.subset(items: [stagingItem, rows.s1]))
        let draft = try await world.open(file, passphrase: passphrase, checkGitHub: false)
        var plan = draft.plan
        let staging = try #require(plan.environments.first)
        #expect(staging.createsEnvironment)
        let pendingWithStaging = plan.pendingChangeCount
        try plan.select(.skip, forItem: try #require(staging.items.first).id)
        let skipped = try #require(plan.environments.first)
        #expect(skipped.action == .create(pending: true))
        #expect(!skipped.createsEnvironment)
        // Neither the skipped item nor the environment create is pending any more.
        #expect(plan.pendingChangeCount == pendingWithStaging - 2)

        let pendingBefore = try world.receiver.pendingCount()
        let result = try await world.receiverSharing.apply(draft, plan: plan, confirmReplay: false)
        #expect(result.environmentsCreated.isEmpty)
        #expect(try world.receiver.environment("staging") == nil)
        // The rest of the selection is still imported.
        #expect(result.added == ["FXV_S1"])
        #expect(try world.receiver.pendingCount() == pendingBefore + 1)
    }

    @Test func aWholeEnvironmentWithEveryItemSkippedIsStillCreated() async throws {
        let world = try await ShareWorld.make()
        defer { world.folder.remove() }
        let (rows, _) = try addSenderStaging(world)
        let stagingID = try #require(try world.sender.environment("staging")).id
        let (file, passphrase) = try await world.export(rows.subset(environments: [stagingID]))
        let draft = try await world.open(file, passphrase: passphrase, checkGitHub: false)
        var plan = draft.plan
        let staging = try #require(plan.environments.first)
        #expect(staging.includesBranchPolicy)
        let item = try #require(staging.items.first { $0.key.name == "FXV_S3" })
        try plan.select(.skip, forItem: item.id)
        #expect(try #require(plan.environments.first).createsEnvironment)
        let result = try await world.receiverSharing.apply(draft, plan: plan, confirmReplay: false)
        #expect(result.environmentsCreated == ["staging"])
        #expect(try world.receiver.environment("staging")?.branchPolicy.kind == .protected)
    }

    // MARK: - FX Vault 0.1.1 files

    /// `Fixtures/Sharing/repository-v1-0.1.1.fxvault`: written by FX Vault 0.1.1's
    /// `SharingRepository.exportFile` (real Argon2id) for the whole `ShareWorld` repository.
    private static let fixturePassphrase = "freeness-outpost-coma-gulp-reforest-womanless"

    @Test func aFileWrittenByVersion011StillImports() async throws {
        let world = try await ShareWorld.make()
        let sharing = SharingRepository(
            session: world.receiver.session,
            schedulers: world.receiver.schedulers,
            deriver: Argon2idSharingDeriver(),
            clock: world.receiver.clock
        )
        let url = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("Sharing/repository-v1-0.1.1.fxvault")
        let file = try sharing.readFile(at: url)
        let draft = try await sharing.openFile(file, passphrase: Self.fixturePassphrase, checkGitHub: false)
        #expect(draft.manifest.schemaVersion == 1)
        #expect(draft.manifest.scope == .repository)
        #expect(draft.manifest.producer.version == "0.1.1")
        let plan = draft.plan
        #expect(plan.blockReason == nil)
        #expect(plan.item("FXV_S1")?.chip == .new)
        #expect(plan.item("FXV_V1")?.chip == .differs)
        #expect(plan.item("FXV_S2", environment: "production")?.chip == .fillsMissingValue)
        let production = try #require(plan.environments.first)
        #expect(production.includesBranchPolicy)
        #expect(production.policyDifference?.decision == .keepMine)

        let result = try await sharing.apply(draft, plan: plan, confirmReplay: plan.requiresReplayConfirmation)
        #expect(result.added.sorted() == ["FXV_S1", "production/FXV_V2"])
        #expect(result.filled == ["production/FXV_S2"])
        let s1 = try #require(try world.receiver.item("FXV_S1", kind: .secret))
        #expect(try world.receiver.value(s1.id) == "a1")
    }

    // MARK: - Helpers

    private static func patterns(_ environment: EnvironmentModel) -> Set<String> {
        Set(environment.branchPolicy.activePatterns.map { "\($0.pattern)|\($0.type.rawValue)" })
    }

    /// Adds a local (never pushed) `staging` environment with `FXV_S3` on the sender.
    private func addSenderStaging(_ world: ShareWorld) throws -> (SenderRows, ConfigItemID) {
        let sender = world.sender
        let repositoryID = try sender.repository().id
        let staging = try sender.config.createEnvironment(in: repositoryID, name: "staging", policy: .protectedBranches)
        let item = try sender.add("FXV_S3", kind: .secret, value: "s3", scope: .environment(staging))
        return (try SenderRows(world), item)
    }
}
