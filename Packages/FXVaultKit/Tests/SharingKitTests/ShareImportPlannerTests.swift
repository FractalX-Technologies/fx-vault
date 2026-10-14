import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// Every §9.5 row of the receiver merge planner.
@Suite("Share import planner")
struct ShareImportPlannerTests {
    // MARK: - Fixture

    static let now = PackageFactory.createdAt.addingTimeInterval(3_600)
    static let earlier = PackageFactory.createdAt.addingTimeInterval(-3_600)
    static let githubTime = Date(timeIntervalSince1970: 1_789_000_000)

    /// Fingerprints are SHA-256 of the value (binding ignored in tests).
    static let fingerprinter: ShareFingerprinter = { _, value in
        value.withUnsafeBytes { Data(SHA256.hash(data: $0)) }
    }

    static func fingerprint(_ text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }

    struct Local {
        var repository: RepoModel
        var environments: [EnvironmentModel] = []
        var items: [ShareLocalItemModel] = []
        var remote: ShareRemoteSnapshotModel?
        var imported: Set<SharePackageID> = []
        var now = ShareImportPlannerTests.now

        init(githubID: String? = PackageFactory.githubRepoID, owner: String = PackageFactory.owner, name: String = PackageFactory.repository) {
            repository = RepoModel(
                accountLogin: "octocat",
                githubID: githubID,
                ownerLogin: owner,
                ownerType: .organization,
                name: name,
                visibility: .private,
                origin: .imported,
                importedAt: ShareImportPlannerTests.earlier
            )
        }

        @discardableResult
        mutating func addEnvironment(_ name: String, policy: DeploymentBranchPolicyModel = .all, isDeleted: Bool = false) -> EnvironmentID {
            let environment = EnvironmentModel(
                repositoryID: repository.id,
                name: name,
                isDeleted: isDeleted,
                branchPolicy: policy,
                createdAt: ShareImportPlannerTests.earlier,
                updatedAt: ShareImportPlannerTests.earlier
            )
            environments.append(environment)
            return environment.id
        }

        mutating func addItem(
            _ name: String,
            kind: ConfigKind = .secret,
            value: String?,
            environment: EnvironmentID? = nil,
            remoteUpdatedAt: Date? = nil,
            updatedAt: Date = ShareImportPlannerTests.earlier,
            isDeleted: Bool = false
        ) {
            let item = ConfigItemModel(
                repositoryID: repository.id,
                scope: ConfigScope(environmentID: environment),
                kind: kind,
                name: name,
                valueState: value == nil ? .missing : .present,
                syncedName: name,
                isDeleted: isDeleted,
                remoteUpdatedAt: remoteUpdatedAt,
                syncStatus: .synced,
                createdAt: ShareImportPlannerTests.earlier,
                updatedAt: updatedAt
            )
            items.append(ShareLocalItemModel(item: item, fingerprint: value.map(ShareImportPlannerTests.fingerprint)))
        }

        var state: ShareLocalStateModel {
            ShareLocalStateModel(
                repository: repository,
                environments: environments,
                items: items,
                remote: remote,
                importedPackageIDs: imported,
                now: now
            )
        }
    }

    static func plan(
        _ package: SharePackageModel,
        _ local: Local,
        mode: SharePackageValidator.Mode = .payload
    ) throws -> ShareImportPlanModel {
        try ShareImportPlanner.plan(package, mode: mode, local: local.state, fingerprint: fingerprinter)
    }

    static func single(_ item: ShareItemModel, kind: ConfigKind = .secret) -> SharePackageModel {
        kind == .secret
            ? PackageFactory.package(secrets: [item])
            : PackageFactory.package(variables: [item])
    }

    // MARK: - No local item → Add

    @Test func newSecretIsPendingAddByDefault() throws {
        let plan = try Self.plan(Self.single(PackageFactory.item("API_KEY", value: "a")), Local())
        let item = try #require(plan.repositoryItems.first)
        #expect(item.chip == .new)
        #expect(item.defaultAction == .add)
        #expect(item.allowedActions == [.add, .skip])
        #expect(item.outcome == .added(pending: true))
        #expect(item.outcome.setsShareProvenance)
        #expect(plan.pendingChangeCount == 1)
    }

    @Test func newSecretIsSyncedWhenGitHubAgrees() throws {
        var local = Local()
        let key = ShareItemKeyModel(environmentName: nil, kind: .secret, name: "API_KEY")
        local.remote = ShareRemoteSnapshotModel(environmentNames: [], items: [ShareRemoteItemModel(key: key, updatedAt: Self.githubTime)])
        let synced = try Self.plan(Self.single(PackageFactory.item("API_KEY", value: "a", githubUpdatedAt: Self.githubTime)), local)
        #expect(synced.repositoryItems.first?.outcome == .added(pending: false))

        let otherTime = try Self.plan(
            Self.single(PackageFactory.item("API_KEY", value: "a", githubUpdatedAt: Self.githubTime.addingTimeInterval(1))),
            local
        )
        #expect(otherTime.repositoryItems.first?.outcome == .added(pending: true))

        let senderPending = try Self.plan(
            Self.single(PackageFactory.item("API_KEY", value: "a", syncState: .pending, githubUpdatedAt: Self.githubTime)),
            local
        )
        #expect(senderPending.repositoryItems.first?.outcome == .added(pending: true))
    }

    @Test func newVariableIsSyncedOnlyWhenTheValueEqualsGitHubs() throws {
        var local = Local()
        let key = ShareItemKeyModel(environmentName: nil, kind: .variable, name: "REGION")
        local.remote = ShareRemoteSnapshotModel(
            environmentNames: [],
            items: [ShareRemoteItemModel(key: key, updatedAt: Self.githubTime, valueFingerprint: Self.fingerprint("eu-west-1"))]
        )
        let same = try Self.plan(Self.single(PackageFactory.item("REGION", value: "eu-west-1"), kind: .variable), local)
        #expect(same.repositoryItems.first?.outcome == .added(pending: false))
        let different = try Self.plan(Self.single(PackageFactory.item("REGION", value: "us-east-1"), kind: .variable), local)
        #expect(different.repositoryItems.first?.outcome == .added(pending: true))
    }

    // MARK: - Local value missing → Fill

    @Test func fillsAMissingValueWithoutPendingWhenTimestampsMatch() throws {
        var local = Local()
        local.addItem("API_KEY", value: nil, remoteUpdatedAt: Self.githubTime)
        let plan = try Self.plan(Self.single(PackageFactory.item("API_KEY", value: "a", githubUpdatedAt: Self.githubTime)), local)
        let item = try #require(plan.repositoryItems.first)
        #expect(item.chip == .fillsMissingValue)
        #expect(item.defaultAction == .fill)
        #expect(item.allowedActions == [.fill, .skip])
        #expect(item.outcome == .filled(pending: false))
        #expect(item.localItemID == local.items.first?.item.id)
        #expect(plan.pendingChangeCount == 0)
    }

    @Test func fillIsPendingModifyWhenTimestampsDiffer() throws {
        var local = Local()
        local.addItem("API_KEY", value: nil, remoteUpdatedAt: Self.githubTime)
        let newer = PackageFactory.item("API_KEY", value: "a", githubUpdatedAt: Self.githubTime.addingTimeInterval(60))
        #expect(try Self.plan(Self.single(newer), local).repositoryItems.first?.outcome == .filled(pending: true))
        let unknown = PackageFactory.item("API_KEY", value: "a", githubUpdatedAt: nil)
        #expect(try Self.plan(Self.single(unknown), local).repositoryItems.first?.outcome == .filled(pending: true))
    }

    // MARK: - Same / Differs

    @Test func identicalValueIsSkipped() throws {
        var local = Local()
        local.addItem("API_KEY", value: "same")
        let item = try #require(try Self.plan(Self.single(PackageFactory.item("API_KEY", value: "same")), local).repositoryItems.first)
        #expect(item.chip == .same)
        #expect(item.defaultAction == .skip)
        #expect(item.allowedActions == [.skip])
        #expect(item.outcome == .unchanged)
    }

    @Test func differentValueKeepsMineUnlessOverwritten() throws {
        var local = Local()
        local.addItem("API_KEY", value: "mine")
        local.addItem("TOKEN", value: "mine")
        let package = PackageFactory.package(secrets: [
            PackageFactory.item("API_KEY", value: "theirs"),
            PackageFactory.item("TOKEN", value: "theirs"),
        ])
        var plan = try Self.plan(package, local)
        let item = try #require(plan.repositoryItems.first)
        #expect(item.chip == .differs)
        #expect(item.defaultAction == .keepMine)
        #expect(item.allowedActions == [.keepMine, .overwrite])
        #expect(item.outcome == .unchanged)
        #expect(item.outcome(for: .overwrite) == .overwritten)
        #expect(plan.pendingChangeCount == 0)

        try plan.select(.overwrite, forItem: item.id)
        #expect(plan.repositoryItems.first?.outcome == .overwritten)
        #expect(plan.pendingChangeCount == 1)
        #expect(throws: ShareError.importActionNotAllowed) { try plan.select(.fill, forItem: item.id) }

        plan.overwriteAll()
        #expect(plan.allItems.allSatisfy { $0.action == .overwrite })
        #expect(plan.pendingChangeCount == 2)
    }

    @Test func unknownFingerprintCountsAsDifferent() throws {
        var local = Local()
        local.addItem("API_KEY", value: "same")
        let plan = try ShareImportPlanner.plan(
            Self.single(PackageFactory.item("API_KEY", value: "same")),
            mode: .payload,
            local: local.state,
            fingerprint: { _, _ in nil }
        )
        #expect(plan.repositoryItems.first?.chip == .differs)
    }

    @Test func matchingIgnoresNameCase() throws {
        var local = Local()
        let environmentID = local.addEnvironment("Producción")
        local.addItem("DB_PASSWORD", value: "same", environment: environmentID)
        let package = PackageFactory.package(environments: [
            PackageFactory.environment("PRODUCCIÓN", secrets: [PackageFactory.item("DB_PASSWORD", value: "same")]),
        ])
        let plan = try Self.plan(package, local)
        #expect(plan.environments.first?.action == .useExisting)
        #expect(plan.environments.first?.localEnvironmentID == environmentID)
        #expect(plan.environments.first?.items.first?.chip == .same)
    }

    // MARK: - Kind collision

    @Test func sameNameUnderTheOtherKindIsSkippedWithAWarning() throws {
        var local = Local()
        local.addItem("TOKEN", kind: .variable, value: "public")
        var plan = try Self.plan(Self.single(PackageFactory.item("TOKEN", value: "secret")), local)
        let item = try #require(plan.repositoryItems.first)
        #expect(item.chip == .otherKindExists)
        #expect(item.defaultAction == .skip)
        #expect(item.allowedActions == [.skip])
        #expect(item.warnings == [.otherKindExists])
        #expect(throws: ShareError.importActionNotAllowed) { try plan.select(.add, forItem: item.id) }
    }

    // MARK: - Incoming value missing

    @Test func missingIncomingValueAddsWithoutValueOrSkips() throws {
        let absent = try Self.plan(Self.single(PackageFactory.item("API_KEY", value: nil)), Local())
        let added = try #require(absent.repositoryItems.first)
        #expect(added.chip == .valueNotIncluded)
        #expect(added.defaultAction == .addWithoutValue)
        #expect(added.outcome == .addedWithoutValue)
        #expect(!added.outcome.isPending)

        var local = Local()
        local.addItem("API_KEY", value: "mine")
        let present = try Self.plan(Self.single(PackageFactory.item("API_KEY", value: nil)), local)
        let skipped = try #require(present.repositoryItems.first)
        #expect(skipped.chip == .valueNotIncluded)
        #expect(skipped.defaultAction == .skip)
        #expect(skipped.allowedActions == [.skip])
    }

    // MARK: - Environments

    @Test func missingEnvironmentIsCreatedPendingUnlessGitHubHasIt() throws {
        let package = PackageFactory.package(environments: [
            PackageFactory.environment("staging", secrets: [PackageFactory.item("KEY", value: "v")]),
        ])
        let plan = try Self.plan(package, Local())
        let environment = try #require(plan.environments.first)
        #expect(environment.action == .create(pending: true))
        #expect(environment.localEnvironmentID == nil)
        #expect(environment.policyDifference == nil)
        #expect(environment.items.first?.chip == .new)
        #expect(plan.pendingChangeCount == 2)

        var local = Local()
        local.remote = ShareRemoteSnapshotModel(environmentNames: ["Staging"], items: [])
        #expect(try Self.plan(package, local).environments.first?.action == .create(pending: false))
    }

    struct PolicyCase: Sendable, CustomTestStringConvertible {
        let label: String
        let local: ShareBranchPolicyModel
        let incoming: ShareBranchPolicyModel
        let isWidening: Bool
        var testDescription: String { label }
    }

    static let main = ShareBranchPatternModel(name: "main", type: .branch)
    static let release = ShareBranchPatternModel(name: "release", type: .branch)
    static let wildcard = ShareBranchPatternModel(name: "release/*", type: .branch)
    static let tagWildcard = ShareBranchPatternModel(name: "v?.?", type: .tag)

    static let policyCases: [PolicyCase] = [
        PolicyCase(label: "protected → all", local: .init(type: .protected), incoming: .init(type: .all), isWidening: true),
        PolicyCase(label: "custom → all", local: .init(type: .custom, patterns: [main]), incoming: .init(type: .all), isWidening: true),
        PolicyCase(label: "custom → protected", local: .init(type: .custom, patterns: [main]), incoming: .init(type: .protected), isWidening: true),
        PolicyCase(label: "added wildcard", local: .init(type: .custom, patterns: [main]), incoming: .init(type: .custom, patterns: [main, wildcard]), isWidening: true),
        PolicyCase(label: "added tag wildcard", local: .init(type: .custom, patterns: [main]), incoming: .init(type: .custom, patterns: [tagWildcard]), isWidening: true),
        PolicyCase(label: "added exact pattern", local: .init(type: .custom, patterns: [main]), incoming: .init(type: .custom, patterns: [main, release]), isWidening: false),
        PolicyCase(label: "removed pattern", local: .init(type: .custom, patterns: [main, wildcard]), incoming: .init(type: .custom, patterns: [main]), isWidening: false),
        PolicyCase(label: "all → protected", local: .init(type: .all), incoming: .init(type: .protected), isWidening: false),
        PolicyCase(label: "all → custom", local: .init(type: .all), incoming: .init(type: .custom, patterns: [wildcard]), isWidening: false),
        PolicyCase(label: "protected → custom", local: .init(type: .protected), incoming: .init(type: .custom, patterns: [main]), isWidening: false),
    ]

    static func vaultPolicy(_ policy: ShareBranchPolicyModel, environmentID: EnvironmentID) -> DeploymentBranchPolicyModel {
        switch policy.type {
        case .all: .all
        case .protected: .protectedBranches
        case .custom: .custom(policy.patterns.map {
            BranchPatternModel(environmentID: environmentID, pattern: $0.name, type: $0.type)
        })
        }
    }

    @Test(arguments: policyCases)
    func differingPolicyKeepsMine(_ policyCase: PolicyCase) throws {
        var local = Local()
        let environmentID = EnvironmentID()
        var environment = EnvironmentModel(
            id: environmentID,
            repositoryID: local.repository.id,
            name: "production",
            branchPolicy: Self.vaultPolicy(policyCase.local, environmentID: environmentID),
            createdAt: Self.earlier,
            updatedAt: Self.earlier
        )
        environment.syncedName = "production"
        local.environments = [environment]
        let package = PackageFactory.package(environments: [PackageFactory.environment("production", policy: policyCase.incoming)])
        var plan = try Self.plan(package, local)
        let planned = try #require(plan.environments.first)
        let difference = try #require(planned.policyDifference)
        #expect(difference.decision == .keepMine)
        #expect(!difference.isPending)
        #expect(difference.isWidening == policyCase.isWidening)
        #expect(plan.pendingChangeCount == 0)

        if policyCase.isWidening {
            #expect(throws: ShareError.importActionNotAllowed) {
                try plan.setPolicyDecision(.useIncoming, forEnvironment: planned.id)
            }
            try plan.setPolicyDecision(.useIncoming, forEnvironment: planned.id, wideningConfirmed: true)
        } else {
            try plan.setPolicyDecision(.useIncoming, forEnvironment: planned.id)
        }
        #expect(plan.environments.first?.policyDifference?.isPending == true)
        #expect(plan.pendingChangeCount == 1)
    }

    @Test func samePolicyInAnyOrderHasNoDifferenceRow() throws {
        var local = Local()
        let environmentID = EnvironmentID()
        local.environments = [EnvironmentModel(
            id: environmentID,
            repositoryID: local.repository.id,
            name: "production",
            branchPolicy: .custom([
                BranchPatternModel(environmentID: environmentID, pattern: "main", type: .branch),
                BranchPatternModel(environmentID: environmentID, pattern: "release/*", type: .branch),
            ]),
            createdAt: Self.earlier,
            updatedAt: Self.earlier
        )]
        let incoming = ShareBranchPolicyModel(type: .custom, patterns: [Self.wildcard, Self.main])
        let package = PackageFactory.package(environments: [PackageFactory.environment("production", policy: incoming)])
        var plan = try Self.plan(package, local)
        #expect(plan.environments.first?.policyDifference == nil)
        let id = try #require(plan.environments.first?.id)
        #expect(throws: ShareError.importActionNotAllowed) { try plan.setPolicyDecision(.useIncoming, forEnvironment: id) }
    }

    @Test func locallyDeletedEnvironmentAndItemAreSkipped() throws {
        var local = Local()
        local.addEnvironment("staging", isDeleted: true)
        local.addItem("API_KEY", value: "mine", isDeleted: true)
        let package = PackageFactory.package(
            secrets: [PackageFactory.item("API_KEY", value: "theirs")],
            environments: [PackageFactory.environment("staging", secrets: [PackageFactory.item("KEY", value: "v")])]
        )
        let plan = try Self.plan(package, local)
        #expect(plan.repositoryItems.first?.chip == .deletedLocally)
        #expect(plan.repositoryItems.first?.allowedActions == [.skip])
        #expect(plan.environments.first?.action == .blockedDeletedLocally)
        #expect(plan.environments.first?.items.first?.chip == .deletedLocally)
        #expect(plan.changedItems.isEmpty)
    }

    // MARK: - Preconditions

    @Test func repositoryIDMismatchBlocks() throws {
        let package = Self.single(PackageFactory.item("API_KEY", value: "a"))
        let other = try Self.plan(package, Local(githubID: "R_other"))
        #expect(other.blockReason == .repositoryIDMismatch)
        #expect(other.allItems.isEmpty)
        let unknownLocally = try Self.plan(package, Local(githubID: nil))
        #expect(unknownLocally.blockReason == .repositoryIDMismatch)
        let noIncomingID = try Self.plan(PackageFactory.package(secrets: [PackageFactory.item("A", value: "a")], githubRepoID: nil), Local(githubID: "R_other"))
        #expect(noIncomingID.blockReason == nil)
    }

    @Test func repositoryMustBeImportedAndMatchByName() throws {
        let package = Self.single(PackageFactory.item("API_KEY", value: "a"))
        let missing = try ShareImportPlanner.plan(
            package,
            mode: .payload,
            local: ShareLocalStateModel(repository: nil, now: Self.now),
            fingerprint: Self.fingerprinter
        )
        #expect(missing.blockReason == .repositoryNotImported)
        #expect(try Self.plan(package, Local(owner: "someone-else")).blockReason == .repositoryNameMismatch)
        #expect(try Self.plan(package, Local(owner: "OCTO-ORG", name: "SERVICE")).blockReason == nil)
    }

    @Test func invalidPackagesAreRejected() {
        var package = Self.single(PackageFactory.item("API_KEY", value: "a"))
        package.repository.host = "evil.example"
        #expect(throws: ShareError.invalidPackage(.invalidHost)) { _ = try Self.plan(package, Local()) }
        #expect(throws: ShareError.invalidPackage(.valueInManifest)) {
            _ = try Self.plan(Self.single(PackageFactory.item("API_KEY", value: "a")), Local(), mode: .manifest)
        }
    }

    // MARK: - Replay

    @Test func replaySignalsNeedConfirmation() throws {
        var local = Local()
        let package = Self.single(PackageFactory.item("API_KEY", value: "a"))
        #expect(try Self.plan(package, local).replayWarnings.isEmpty)

        local.imported = [package.packageID]
        let replayed = try Self.plan(package, local)
        #expect(replayed.replayWarnings == [.alreadyImported])
        #expect(replayed.requiresReplayConfirmation)

        var old = Local()
        old.now = PackageFactory.createdAt.addingTimeInterval(Timeouts.shareReplayMaxAge.timeInterval + 1)
        #expect(try Self.plan(package, old).replayWarnings == [.olderThanMaxAge])

        var changed = Local()
        changed.addItem("API_KEY", value: "mine", updatedAt: PackageFactory.createdAt.addingTimeInterval(1))
        let stale = try Self.plan(package, changed)
        #expect(stale.replayWarnings == [.olderThanLocalChanges])
        #expect(stale.repositoryItems.first?.warnings.contains(.localChangedSincePackage) == true)
    }

    // MARK: - Provenance and modes

    @Test func originCarriesPackageAndSender() throws {
        let package = Self.single(PackageFactory.item("API_KEY", value: "a"))
        let plan = try Self.plan(package, Local())
        #expect(plan.origin == ShareOriginModel(packageID: package.packageID, senderName: "Bryan"))
        #expect(plan.packageID == package.packageID)
        #expect(ShareItemOutcome.filled(pending: false).setsShareProvenance)
        #expect(ShareItemOutcome.addedWithoutValue.setsShareProvenance)
        #expect(!ShareItemOutcome.unchanged.setsShareProvenance)
    }

    @Test func manifestPreviewShowsExistsLocallyInsteadOfSameOrDiffers() throws {
        var local = Local()
        local.addItem("API_KEY", value: "same")
        local.addItem("TOKEN", value: nil)
        let package = PackageFactory.package(secrets: [
            PackageFactory.item("API_KEY", value: "same"),
            PackageFactory.item("TOKEN", value: "t"),
            PackageFactory.item("NEW_ONE", value: "n"),
            PackageFactory.item("NO_VALUE", value: nil),
        ])
        let preview = try Self.plan(package.manifest(), local, mode: .manifest)
        #expect(preview.repositoryItems.map(\.chip) == [.existsLocally, .fillsMissingValue, .new, .valueNotIncluded])
        #expect(preview.mode == .manifest)

        let full = try Self.plan(package, local, mode: .payload)
        #expect(full.repositoryItems.map(\.chip) == [.same, .fillsMissingValue, .new, .valueNotIncluded])
    }
}
