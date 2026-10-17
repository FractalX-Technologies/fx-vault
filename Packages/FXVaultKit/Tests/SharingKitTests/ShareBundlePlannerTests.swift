import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// The bundle planner (v0.9.0, P7–P9): repository status, destinations, folders, links, freshness
/// and replay.
@Suite("Share bundle planner")
struct ShareBundlePlannerTests {
    // MARK: - Fixture

    static let now = BundleFactory.createdAt.addingTimeInterval(3_600)
    static let earlier = BundleFactory.createdAt.addingTimeInterval(-3_600)

    /// Fingerprints are SHA-256 of the value (binding ignored in tests).
    static let fingerprinter: ShareFingerprinter = { _, value in
        value.withUnsafeBytes { Data(SHA256.hash(data: $0)) }
    }

    static let destinationFingerprinter: ShareDestinationFingerprinter = { _, value in
        value.withUnsafeBytes { Data(SHA256.hash(data: $0)) }
    }

    static func fingerprint(_ text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }

    static func localRepository(_ name: String, githubID: String?) -> RepoModel {
        RepoModel(
            accountLogin: "user-a",
            githubID: githubID,
            ownerLogin: BundleFactory.owner,
            ownerType: .organization,
            name: name,
            visibility: .private,
            origin: .imported,
            importedAt: earlier
        )
    }

    static func localItem(
        _ name: String,
        value: String?,
        repository: RepoModel,
        updatedAt: Date = earlier
    ) -> ShareLocalItemModel {
        let item = ConfigItemModel(
            repositoryID: repository.id,
            scope: ConfigScope(environmentID: nil),
            kind: .secret,
            name: name,
            valueState: value == nil ? .missing : .present,
            syncedName: name,
            syncStatus: .synced,
            createdAt: earlier,
            updatedAt: updatedAt
        )
        return ShareLocalItemModel(item: item, fingerprint: value.map(fingerprint))
    }

    static func localDestination(
        _ target: DestinationTargetModel,
        repository: RepoModel,
        items: [(name: String, kind: ConfigKind, value: String?, isDeleted: Bool, updatedAt: Date)] = []
    ) -> ShareLocalDestinationModel {
        let destination = DestinationModel(
            repositoryID: repository.id,
            target: target,
            stage: "staging",
            connectionID: nil,
            sortOrder: 0,
            createdAt: earlier,
            updatedAt: earlier
        )
        return ShareLocalDestinationModel(
            destination: destination,
            items: items.map { entry in
                ShareLocalDestinationItemModel(
                    item: DestinationItemModel(
                        destinationID: destination.id,
                        kind: entry.kind,
                        name: entry.name,
                        valueState: entry.value == nil ? .missing : .present,
                        syncedName: entry.name,
                        isDeleted: entry.isDeleted,
                        syncStatus: .synced,
                        createdAt: earlier,
                        updatedAt: entry.updatedAt
                    ),
                    fingerprint: entry.value.map(fingerprint)
                )
            }
        )
    }

    static func plan(
        _ bundle: ShareBundleModel,
        repositories: [String: ShareBundleRepositoryStateModel],
        folders: [ShareLocalFolderModel] = [],
        imported: Set<SharePackageID> = [],
        now: Date = now
    ) throws -> ShareBundlePlanModel {
        try ShareBundlePlanner.plan(
            bundle,
            mode: .payload,
            local: ShareBundleLocalStateModel(
                repositories: repositories,
                folders: folders,
                importedPackageIDs: imported,
                now: now
            ),
            fingerprint: fingerprinter,
            destinationFingerprint: destinationFingerprinter
        )
    }

    static func key(_ name: String) -> String {
        "\(BundleFactory.owner)/\(name)"
    }

    /// web: secret API_KEY linked to its Vercel copy; api: a Key Vault destination.
    static func linkedBundle(webValue: String = "one", vercelValue: String = "one") -> ShareBundleModel {
        BundleFactory.bundle(repositories: [
            BundleFactory.repository(
                BundleFactory.web,
                githubRepoID: BundleFactory.webRepoID,
                secrets: [BundleFactory.item("API_KEY", value: webValue, link: BundleFactory.linkToken)],
                destinations: [
                    ShareDestinationModel(
                        target: BundleFactory.vercelPreview,
                        stage: "staging",
                        secrets: [BundleFactory.item("API_KEY", value: vercelValue, link: BundleFactory.linkToken)]
                    ),
                ]
            ),
        ])
    }

    // MARK: - Repository status

    @Test func eachRepositoryGetsItsStatus() throws {
        let names = ["in-vault", "importable", "hidden", "unreachable", "unchecked", "renamed"]
        let bundle = BundleFactory.bundle(repositories: names.map {
            BundleFactory.repository($0, githubRepoID: "R_\($0.replacingOccurrences(of: "-", with: ""))", secrets: [BundleFactory.item("API_KEY")])
        })
        let plan = try Self.plan(bundle, repositories: [
            Self.key("in-vault"): ShareBundleRepositoryStateModel(repository: Self.localRepository("in-vault", githubID: "R_invault")),
            Self.key("importable"): ShareBundleRepositoryStateModel(repository: nil, access: .importable(accountLogin: "user-a")),
            Self.key("hidden"): ShareBundleRepositoryStateModel(repository: nil, access: .notVisible),
            Self.key("unreachable"): ShareBundleRepositoryStateModel(repository: nil, access: .unreachable),
            Self.key("renamed"): ShareBundleRepositoryStateModel(repository: Self.localRepository("renamed", githubID: "R_other")),
        ])
        #expect(plan.repositories.map(\.status) == [
            .inVault,
            .willImportFromGitHub(accountLogin: "user-a"),
            .noAccess(.notVisible),
            .noAccess(.unreachable),
            .noAccess(.notChecked),
            .blocked(.repositoryIDMismatch),
        ])
        #expect(plan.importedRepositories.map(\.name) == ["in-vault"])
        #expect(plan.repositoriesToImport.map(\.name) == ["importable"])
        #expect(plan.repositories[0].githubPlan?.repositoryItems.first?.chip == .new)
        #expect(plan.repositories.dropFirst().allSatisfy { $0.githubPlan == nil })
        #expect(plan.repositories[2].summary.itemCount == 1)
        #expect(plan.changedItemCount == 1)
    }

    @Test func aRepositoryToImportPlansItsDestinationsAsNew() throws {
        let bundle = BundleFactory.sample()
        let plan = try Self.plan(bundle, repositories: [
            Self.key(BundleFactory.api): ShareBundleRepositoryStateModel(repository: nil, access: .importable(accountLogin: nil)),
        ])
        let api = plan.repositories[1]
        #expect(api.status == .willImportFromGitHub(accountLogin: nil))
        #expect(api.destinations.map(\.action) == [.create, .create])
        #expect(api.destinations.flatMap(\.items).map(\.chip) == [.new, .new])
        // Selections only apply to repositories imported now.
        let itemID = try #require(api.destinations.first?.items.first?.id)
        var editable = plan
        #expect(throws: ShareError.importActionNotAllowed) { try editable.select(.skip, forItem: itemID) }
    }

    // MARK: - Destinations

    @Test func destinationsMergeByTargetKeyOrAreCreated() throws {
        let local = Self.localRepository(BundleFactory.web, githubID: BundleFactory.webRepoID)
        let existing = Self.localDestination(
            .vercel(projectID: "PRJ_SAMPLE", projectName: "example-web", teamID: "TEAM_SAMPLE", environment: .preview),
            repository: local,
            items: [
                ("SAME", .secret, "same", false, Self.earlier),
                ("DIFFERS", .secret, "mine", false, Self.earlier),
                ("MISSING_HERE", .secret, nil, false, Self.earlier),
                ("GONE", .secret, "old", true, Self.earlier),
                ("OTHER_KIND", .variable, "plain", false, Self.earlier),
            ]
        )
        let bundle = BundleFactory.bundle(repositories: [
            BundleFactory.repository(
                BundleFactory.web,
                githubRepoID: BundleFactory.webRepoID,
                destinations: [
                    ShareDestinationModel(
                        target: BundleFactory.vercelPreview,
                        stage: "staging",
                        secrets: [
                            BundleFactory.item("SAME", value: "same"),
                            BundleFactory.item("DIFFERS", value: "theirs"),
                            BundleFactory.item("MISSING_HERE", value: "filled"),
                            BundleFactory.item("GONE", value: "new"),
                            BundleFactory.item("OTHER_KIND", value: "secret"),
                            BundleFactory.item("BRAND_NEW", value: "new"),
                            BundleFactory.item("NO_VALUE", value: nil),
                        ],
                        variables: [BundleFactory.item("NEXT_PUBLIC_SITE_URL", value: "https://example.test")],
                        publicNames: ["NEXT_PUBLIC_SITE_URL"]
                    ),
                    ShareDestinationModel(target: BundleFactory.keyVault, stage: "staging", secrets: [BundleFactory.item("DATABASE_URL")]),
                ]
            ),
        ])
        let plan = try Self.plan(bundle, repositories: [
            Self.key(BundleFactory.web): ShareBundleRepositoryStateModel(repository: local, destinations: [existing]),
        ])
        let destinations = try #require(plan.repositories.first?.destinations)
        #expect(destinations[0].action == .useExisting(existing.destination.id))
        #expect(destinations[0].localDestinationID == existing.destination.id)
        #expect(destinations[1].action == .create)
        let items = destinations[0].items
        #expect(items.map(\.chip) == [.same, .differs, .fillsMissingValue, .deletedLocally, .otherKindExists, .new, .valueNotIncluded, .new])
        #expect(items.map(\.defaultAction) == [.skip, .keepMine, .fill, .skip, .skip, .add, .addWithoutValue, .add])
        #expect(items[1].allowedActions == [.keepMine, .overwrite])
        #expect(items[1].outcome == .unchanged)
        #expect(items[1].outcome(for: .overwrite) == .overwritten)
        #expect(items[2].outcome == .filled(pending: true))
        #expect(items[5].outcome == .added(pending: true))
        #expect(items[7].isPublic)
        #expect(!items[5].isPublic)
        #expect(items[0].localItemID != nil)
        #expect(items[4].localItemID == nil)
        #expect(plan.changedItemCount == 5)
    }

    @Test func overwriteAndOverwriteAllReachDestinationItems() throws {
        let local = Self.localRepository(BundleFactory.web, githubID: BundleFactory.webRepoID)
        let existing = Self.localDestination(
            BundleFactory.vercelPreview,
            repository: local,
            items: [("API_KEY", .secret, "mine", false, Self.earlier)]
        )
        var plan = try Self.plan(Self.linkedBundle(vercelValue: "theirs"), repositories: [
            Self.key(BundleFactory.web): ShareBundleRepositoryStateModel(repository: local, destinations: [existing]),
        ])
        let itemID = try #require(plan.repositories[0].destinations[0].items.first?.id)
        #expect(throws: ShareError.importActionNotAllowed) { try plan.select(.fill, forItem: itemID) }
        plan.overwriteAll()
        #expect(plan.repositories[0].destinations[0].items[0].action == .overwrite)
        try plan.select(.keepMine, forItem: itemID)
        #expect(plan.repositories[0].destinations[0].items[0].action == .keepMine)
    }

    // MARK: - Links

    @Test func linksAreRecreatedForTheRowsThatAreWritten() throws {
        let local = Self.localRepository(BundleFactory.web, githubID: BundleFactory.webRepoID)
        var plan = try Self.plan(Self.linkedBundle(), repositories: [
            Self.key(BundleFactory.web): ShareBundleRepositoryStateModel(repository: local),
        ])
        let githubID = try #require(plan.repositories[0].githubPlan?.repositoryItems.first?.id)
        let vercelID = try #require(plan.repositories[0].destinations.first?.items.first?.id)
        #expect(plan.linkGroups == [ShareLinkGroupModel(token: BundleFactory.linkToken, memberIDs: [githubID, vercelID].sorted())])
        try plan.select(.skip, forItem: vercelID)
        #expect(plan.linkGroups.isEmpty)
    }

    @Test func aKeptRowKeepsItsOwnLink() throws {
        let local = Self.localRepository(BundleFactory.web, githubID: BundleFactory.webRepoID)
        var plan = try Self.plan(Self.linkedBundle(webValue: "theirs"), repositories: [
            Self.key(BundleFactory.web): ShareBundleRepositoryStateModel(
                repository: local,
                items: [Self.localItem("API_KEY", value: "mine", repository: local)]
            ),
        ])
        // Keep mine on GitHub plus a new Vercel row: only one member is written, so no group.
        #expect(plan.repositories[0].githubPlan?.repositoryItems.first?.action == .keepMine)
        #expect(plan.linkGroups.isEmpty)
        let githubID = try #require(plan.repositories[0].githubPlan?.repositoryItems.first?.id)
        try plan.select(.overwrite, forItem: githubID)
        #expect(plan.linkGroups.first?.memberIDs.count == 2)
    }

    @Test func linksAcrossFoldersFollowTheFolderAction() throws {
        let local = Self.localRepository(BundleFactory.web, githubID: BundleFactory.webRepoID)
        let bundle = BundleFactory.bundle(
            repositories: [
                BundleFactory.repository(
                    BundleFactory.web,
                    githubRepoID: BundleFactory.webRepoID,
                    secrets: [BundleFactory.item("FIREBASE_KEY", link: BundleFactory.linkToken)]
                ),
            ],
            folders: [
                ShareBundleFolderModel(name: "Mobile App", secrets: [BundleFactory.item("FIREBASE_KEY", link: BundleFactory.linkToken)]),
            ]
        )
        let folder = FolderModel(name: "mobile app", sortOrder: 0, createdAt: Self.earlier, updatedAt: Self.earlier)
        var plan = try Self.plan(
            bundle,
            repositories: [Self.key(BundleFactory.web): ShareBundleRepositoryStateModel(repository: local)],
            folders: [ShareLocalFolderModel(folder: folder, items: [ShareLocalFolderItemModel(kind: .secret, name: "firebase_key")])]
        )
        let folderPlan = try #require(plan.folders.first)
        #expect(folderPlan.existingFolderID == folder.id)
        #expect(folderPlan.action == .mergeInto(folder.id, conflicts: .keepMine))
        #expect(folderPlan.conflictingItemIDs.count == 1)
        #expect(plan.linkGroups.isEmpty)
        try plan.setFolderAction(.mergeInto(folder.id, conflicts: .replace), forFolder: folderPlan.id)
        #expect(plan.linkGroups.first?.memberIDs.count == 2)
        try plan.setFolderAction(.skip, forFolder: folderPlan.id)
        #expect(plan.linkGroups.isEmpty)
    }

    // MARK: - Folders

    @Test func foldersAreCreatedOrMergedIntoTheirNamesake() throws {
        let bundle = BundleFactory.sample()
        var plan = try Self.plan(bundle, repositories: [:])
        let folderPlan = try #require(plan.folders.first)
        #expect(folderPlan.action == .createNew(name: "Mobile App"))
        #expect(folderPlan.existingFolderID == nil)
        #expect(folderPlan.counts == ShareItemCountModel(secrets: 1, variables: 1))
        try plan.setFolderAction(.createNew(name: "Mobile App 2"), forFolder: folderPlan.id)
        #expect(plan.folders[0].action == .createNew(name: "Mobile App 2"))
        #expect(throws: ShareError.importActionNotAllowed) {
            try plan.setFolderAction(.mergeInto(FolderID(), conflicts: .keepMine), forFolder: folderPlan.id)
        }
        #expect(throws: ShareError.importActionNotAllowed) {
            try plan.setFolderAction(.skip, forFolder: ShareEntryID())
        }
    }

    // MARK: - Freshness and replay

    @Test func anExpiredFileIsRefused() throws {
        let bundle = BundleFactory.sample()
        let skew = Timeouts.shareClockSkew.timeInterval
        #expect(throws: ShareError.expired) {
            _ = try Self.plan(bundle, repositories: [:], now: bundle.expiresAt.addingTimeInterval(skew + 1))
        }
        _ = try Self.plan(bundle, repositories: [:], now: bundle.expiresAt.addingTimeInterval(skew - 1))
    }

    @Test func aFileFromTheFutureIsRefused() {
        let bundle = BundleFactory.sample()
        let skew = Timeouts.shareClockSkew.timeInterval
        #expect(throws: ShareError.invalidPackage(.createdInFuture)) {
            _ = try Self.plan(bundle, repositories: [:], now: bundle.createdAt.addingTimeInterval(-skew - 1))
        }
    }

    @Test func anInvalidBundleIsRefusedBeforePlanning() {
        var bundle = BundleFactory.sample()
        bundle.repositories[0].destinations[0].publicNames = ["MISSING"]
        #expect(throws: ShareError.invalidPackage(.invalidPublicName)) {
            _ = try Self.plan(bundle, repositories: [:])
        }
    }

    @Test func replayIsCheckedForTheWholePackage() throws {
        let bundle = BundleFactory.bundle(
            repositories: [BundleFactory.repository(BundleFactory.web, githubRepoID: BundleFactory.webRepoID)],
            expiry: .thirtyDays
        )
        let skipped = try Self.plan(bundle, repositories: [:], imported: [bundle.packageID])
        #expect(skipped.replayWarnings == [.alreadyImported])
        #expect(skipped.requiresReplayConfirmation)

        let old = try Self.plan(bundle, repositories: [:], now: bundle.createdAt.addingTimeInterval(8 * 86_400))
        #expect(old.replayWarnings == [.olderThanMaxAge])

        let fresh = try Self.plan(bundle, repositories: [:])
        #expect(fresh.replayWarnings.isEmpty)
    }

    @Test func aDestinationChangedSinceThePackageRaisesTheReplayWarning() throws {
        let local = Self.localRepository(BundleFactory.web, githubID: BundleFactory.webRepoID)
        let later = BundleFactory.createdAt.addingTimeInterval(60)
        let existing = Self.localDestination(
            BundleFactory.vercelPreview,
            repository: local,
            items: [("API_KEY", .secret, "mine", false, later)]
        )
        let plan = try Self.plan(Self.linkedBundle(), repositories: [
            Self.key(BundleFactory.web): ShareBundleRepositoryStateModel(repository: local, destinations: [existing]),
        ])
        #expect(plan.replayWarnings == [.olderThanLocalChanges])
        #expect(plan.repositories[0].destinations[0].items[0].warnings == [.localChangedSincePackage])
    }

    // MARK: - Preview comparison

    @Test func selectionsDoNotChangeThePreview() throws {
        let local = Self.localRepository(BundleFactory.web, githubID: BundleFactory.webRepoID)
        let state = [Self.key(BundleFactory.web): ShareBundleRepositoryStateModel(repository: local)]
        let bundle = Self.linkedBundle()
        var plan = try Self.plan(bundle, repositories: state)
        let vercelID = try #require(plan.repositories[0].destinations.first?.items.first?.id)
        try plan.select(.skip, forItem: vercelID)
        let fresh = try Self.plan(bundle, repositories: state)
        #expect(plan.isSamePreview(as: fresh))
        #expect(plan != fresh)

        let changed = try Self.plan(bundle, repositories: [
            Self.key(BundleFactory.web): ShareBundleRepositoryStateModel(
                repository: local,
                items: [Self.localItem("API_KEY", value: "mine", repository: local)]
            ),
        ])
        #expect(!plan.isSamePreview(as: changed))
    }

    @Test func originAndStagesComeFromTheBundle() throws {
        let bundle = BundleFactory.sample()
        let plan = try Self.plan(bundle, repositories: [:])
        #expect(plan.origin == ShareOriginModel(packageID: bundle.packageID, senderName: "Sam"))
        #expect(plan.firstStage == "staging")
        #expect(plan.mode == .payload)
    }
}
