import Foundation
import Testing
import VaultCore
@testable import SharingKit

// MARK: - Fixture

/// Bundles for the schema 4 tests (v0.9.0). Placeholder names only.
enum BundleFactory {
    static let createdAt = Date(timeIntervalSince1970: 1_790_000_000)
    static let owner = "owner-a"
    static let web = "example-web"
    static let api = "example-api"
    static let webRepoID = "R_kgDOWebAAA"
    static let apiRepoID = "R_kgDOApiBBB"
    static let keyVault = DestinationTargetModel.azureKeyVault(vaultName: "kv-example-staging", tenantID: nil)
    static let supabase = DestinationTargetModel.supabase(projectRef: "abcdefghijklmnopqrst")
    static let vercelPreview = DestinationTargetModel.vercel(
        projectID: "prj_sample",
        projectName: "example-web",
        teamID: "team_sample",
        environment: .preview
    )
    /// Joined at runtime so the gitleaks `generic-api-key` rule does not read a fixed per-file
    /// link token as a credential.
    static let linkToken = ["6f1c2a3b", "4d5e", "4f60", "8a71", "92b3c4d5e6f7"].joined(separator: "-")

    static func item(_ name: String, value: String? = "value-\(UUID().uuidString)", link: String? = nil) -> ShareItemModel {
        ShareItemModel(
            name: name,
            value: value.map { SecretBytes(utf8: $0) },
            valueState: value == nil ? .missing : .present,
            githubUpdatedAt: nil,
            syncState: .pending,
            linkToken: link
        )
    }

    static func repository(
        _ name: String,
        owner: String = owner,
        githubRepoID: String? = nil,
        secrets: [ShareItemModel] = [],
        variables: [ShareItemModel] = [],
        environments: [ShareEnvironmentModel] = [],
        destinations: [ShareDestinationModel] = []
    ) -> ShareBundleRepositoryModel {
        ShareBundleRepositoryModel(
            repository: ShareRepositoryModel(
                owner: owner,
                name: name,
                githubRepoID: githubRepoID,
                secrets: secrets,
                variables: variables,
                environments: environments
            ),
            destinations: destinations
        )
    }

    static func bundle(
        repositories: [ShareBundleRepositoryModel] = [],
        folders: [ShareBundleFolderModel] = [],
        stages: [String] = ["staging"],
        createdAt: Date = createdAt,
        expiry: ShareExpiryChoice = .sevenDays,
        packageID: SharePackageID = SharePackageID()
    ) -> ShareBundleModel {
        ShareBundleModel(
            packageID: packageID,
            createdAt: createdAt,
            expiry: expiry,
            producer: ShareProducerModel(version: "0.9.0"),
            sender: ShareSenderModel(displayName: "Sam"),
            stages: stages,
            repositories: repositories,
            folders: folders
        )
    }

    /// Two repositories, the three providers, a partial environment, a folder and one link group
    /// (a repository-level secret and its Vercel copy).
    static func sample() -> ShareBundleModel {
        bundle(
            repositories: [
                repository(
                    web,
                    githubRepoID: webRepoID,
                    secrets: [item("API_KEY", link: linkToken), item("WEBHOOK_SECRET", value: nil)],
                    variables: [item("REGION")],
                    environments: [
                        ShareEnvironmentModel(name: "staging", deploymentBranchPolicy: nil, secrets: [item("DATABASE_URL")]),
                    ],
                    destinations: [
                        ShareDestinationModel(
                            target: vercelPreview,
                            stage: "staging",
                            secrets: [item("API_KEY", link: linkToken)],
                            variables: [item("NEXT_PUBLIC_SITE_URL")],
                            publicNames: ["NEXT_PUBLIC_SITE_URL"]
                        ),
                    ]
                ),
                repository(
                    api,
                    githubRepoID: apiRepoID,
                    destinations: [
                        ShareDestinationModel(target: keyVault, stage: "staging", secrets: [item("DATABASE_URL")]),
                        ShareDestinationModel(target: supabase, stage: nil, secrets: [item("STRIPE_KEY")]),
                    ]
                ),
            ],
            folders: [ShareBundleFolderModel(name: "Mobile App", secrets: [item("FIREBASE_KEY")], variables: [item("BUNDLE_ID")])]
        )
    }
}

// MARK: - Model and coder

@Suite("Share bundle model")
struct ShareBundleModelTests {
    private func json(_ bundle: ShareBundleModel) throws -> [String: Any] {
        let bytes = try ShareBundleCoder.encode(bundle)
        let data = bytes.withUnsafeBytes { Data($0) }
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func encodesTheDocumentedSchema() throws {
        let bundle = BundleFactory.sample()
        let document = try json(bundle)
        #expect(document["schema"] as? String == "io.fractalx.fxvault.share")
        #expect(document["schemaVersion"] as? Int == 4)
        #expect(document["scope"] as? String == "bundle")
        #expect(document["createdAt"] as? String == "2026-09-21T14:13:20Z")
        #expect(document["expiresAt"] as? String == "2026-09-28T14:13:20Z")
        #expect(document["stages"] as? [String] == ["staging"])
        let repositories = try #require(document["repositories"] as? [[String: Any]])
        #expect(repositories.count == 2)
        let web = repositories[0]
        #expect(Set(web.keys) == ["host", "owner", "name", "githubRepoId", "secrets", "variables", "environments", "destinations"])
        let secrets = try #require(web["secrets"] as? [[String: Any]])
        #expect(secrets[0]["link"] as? String == BundleFactory.linkToken)
        #expect(secrets[1]["link"] == nil)
        let environments = try #require(web["environments"] as? [[String: Any]])
        #expect(environments[0]["deploymentBranchPolicy"] is NSNull)
        let vercel = try #require((web["destinations"] as? [[String: Any]])?.first)
        #expect(Set(vercel.keys) == ["id", "stage", "target", "secrets", "variables", "publicNames"])
        let target = try #require(vercel["target"] as? [String: Any])
        #expect(target["provider"] as? String == "vercel")
        #expect(target["projectId"] as? String == "prj_sample")
        #expect(target["teamId"] as? String == "team_sample")
        #expect(target["environment"] as? String == "preview")
        #expect(vercel["publicNames"] as? [String] == ["NEXT_PUBLIC_SITE_URL"])
        let apiDestinations = try #require(repositories[1]["destinations"] as? [[String: Any]])
        let keyVault = try #require(apiDestinations[0]["target"] as? [String: Any])
        #expect(keyVault["provider"] as? String == "azureKeyVault")
        #expect(keyVault["vaultName"] as? String == "kv-example-staging")
        #expect(keyVault["tenantId"] is NSNull)
        #expect(apiDestinations[1]["stage"] is NSNull)
        let supabase = try #require(apiDestinations[1]["target"] as? [String: Any])
        #expect(supabase["projectRef"] as? String == "abcdefghijklmnopqrst")
        let folder = try #require((document["folders"] as? [[String: Any]])?.first)
        #expect(Set(folder.keys) == ["id", "name", "secrets", "variables"])
    }

    /// The exact bytes of a small bundle: sorted keys, explicit nulls, whole-second dates.
    @Test func goldenJSON() throws {
        let bundle = ShareBundleModel(
            packageID: try #require(SharePackageID(uuidString: "11111111-1111-4111-8111-111111111111")),
            createdAt: BundleFactory.createdAt,
            expiry: .oneDay,
            producer: ShareProducerModel(version: "0.9.0"),
            sender: ShareSenderModel(displayName: "Sam"),
            stages: ["staging"],
            repositories: [
                ShareBundleRepositoryModel(
                    repository: ShareRepositoryModel(
                        owner: "owner-a",
                        name: "example-web",
                        githubRepoID: nil,
                        secrets: [
                            ShareItemModel(
                                id: try #require(ShareEntryID(uuidString: "22222222-2222-4222-8222-222222222222")),
                                name: "API_KEY",
                                value: SecretBytes(utf8: "one"),
                                valueState: .present,
                                githubUpdatedAt: nil,
                                syncState: .synced,
                                linkToken: BundleFactory.linkToken
                            ),
                        ]
                    ),
                    destinations: [
                        ShareDestinationModel(
                            id: try #require(ShareEntryID(uuidString: "33333333-3333-4333-8333-333333333333")),
                            target: .supabase(projectRef: "abcdefghijklmnopqrst"),
                            stage: "staging",
                            secrets: [
                                ShareItemModel(
                                    id: try #require(ShareEntryID(uuidString: "44444444-4444-4444-8444-444444444444")),
                                    name: "API_KEY",
                                    value: SecretBytes(utf8: "one"),
                                    valueState: .present,
                                    githubUpdatedAt: nil,
                                    syncState: .pending,
                                    linkToken: BundleFactory.linkToken
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
        let text = try #require(try ShareBundleCoder.encode(bundle).utf8String())
        let item = { (id: String, state: String) in
            "{\"githubUpdatedAt\":null,\"id\":\"\(id)\",\"link\":\"\(BundleFactory.linkToken)\",\"name\":\"API_KEY\","
                + "\"syncState\":\"\(state)\",\"value\":\"one\",\"valueState\":\"present\"}"
        }
        let expected = "{\"createdAt\":\"2026-09-21T14:13:20Z\",\"expiresAt\":\"2026-09-22T14:13:20Z\",\"folders\":[],"
            + "\"packageId\":\"11111111-1111-4111-8111-111111111111\",\"producer\":{\"app\":\"FX Vault\",\"version\":\"0.9.0\"},"
            + "\"repositories\":[{\"destinations\":[{\"id\":\"33333333-3333-4333-8333-333333333333\",\"publicNames\":[],"
            + "\"secrets\":[\(item("44444444-4444-4444-8444-444444444444", "pending"))],\"stage\":\"staging\","
            + "\"target\":{\"projectRef\":\"abcdefghijklmnopqrst\",\"provider\":\"supabase\"},\"variables\":[]}],"
            + "\"environments\":[],\"githubRepoId\":null,\"host\":\"github.com\",\"name\":\"example-web\",\"owner\":\"owner-a\","
            + "\"secrets\":[\(item("22222222-2222-4222-8222-222222222222", "synced"))],\"variables\":[]}],"
            + "\"schema\":\"io.fractalx.fxvault.share\",\"schemaVersion\":4,\"scope\":\"bundle\",\"sender\":{\"displayName\":\"Sam\"},"
            + "\"stages\":[\"staging\"]}"
        #expect(text == expected)
        #expect(try ShareBundleCoder.decode(SecretBytes(utf8: expected)) == bundle)
    }

    @Test func roundTripsThroughJSON() throws {
        let bundle = BundleFactory.sample()
        let decoded = try ShareBundleCoder.decode(try ShareBundleCoder.encode(bundle))
        #expect(decoded == bundle)
        try ShareBundleValidator.validate(decoded, mode: .payload)
    }

    @Test func decodingFailuresAreInvalidFile() throws {
        var text = try #require(try ShareBundleCoder.encode(BundleFactory.sample()).utf8String())
        text = text.replacingOccurrences(of: "\"scope\":\"bundle\"", with: "\"scope\":\"repository\"")
        for input in ["", "[]", "{}", "{\"schemaVersion\":4}", text] {
            #expect(throws: ShareError.invalidFile) { _ = try ShareBundleCoder.decode(SecretBytes(utf8: input)) }
        }
    }

    @Test func manifestStripsEveryValue() throws {
        let bundle = BundleFactory.sample()
        let manifest = bundle.manifest()
        #expect(manifest.allItems.allSatisfy { $0.item.value == nil })
        #expect(manifest.allItems.map(\.item.valueState) == bundle.allItems.map(\.item.valueState))
        #expect(manifest.allEntryIDs == bundle.allEntryIDs)
        try ShareBundleValidator.validate(manifest, mode: .manifest)
        let text = try #require(try ShareBundleCoder.encode(manifest).utf8String())
        for located in bundle.allItems {
            if let value = located.item.value?.utf8String() {
                #expect(!text.contains(value))
            }
        }
        // The original keeps its values, in destinations and folders too.
        #expect(bundle.repositories[1].destinations[0].secrets[0].value != nil)
        #expect(bundle.folders[0].secrets[0].value != nil)
    }

    @Test func wipeZeroesEveryBufferIncludingDestinationsAndFolders() {
        let bundle = BundleFactory.sample()
        let copy = bundle
        bundle.wipeValues()
        let values = copy.allItems.compactMap(\.item.value)
        #expect(values.count == 9)
        #expect(values.allSatisfy { $0.isWiped })
    }

    @Test func itemsAreListedWithTheirPlace() throws {
        let bundle = BundleFactory.sample()
        #expect(bundle.itemCount == 10)
        let vercelID = bundle.repositories[0].destinations[0].id
        let places = bundle.allItems.map(\.place)
        #expect(places.contains(.environment(repository: 0, name: "staging")))
        #expect(places.contains(.destination(repository: 0, id: vercelID)))
        #expect(places.contains(.folder(id: bundle.folders[0].id)))
        #expect(bundle.linkGroups[BundleFactory.linkToken]?.count == 2)
        let located = try #require(bundle.item(withID: bundle.repositories[1].destinations[1].secrets[0].id))
        #expect(located.item.name == "STRIPE_KEY")
    }

    @Test func summaryCountsGitHubScopesDestinationsAndFolders() {
        let summary = BundleFactory.sample().contentSummary
        #expect(summary.repositories.map(\.fullName) == ["owner-a/example-web", "owner-a/example-api"])
        #expect(summary.repositories[0].content.itemCount == 4)
        #expect(summary.repositories[0].destinations[0].counts == ShareItemCountModel(secrets: 1, variables: 1))
        #expect(summary.folders[0].counts.total == 2)
        #expect(summary.itemCount == 10)
    }

    @Test func githubPackageIsASchemaTwoRepositoryPackageWithoutLinks() throws {
        let bundle = BundleFactory.sample()
        let package = bundle.githubPackage(for: bundle.repositories[0])
        #expect(package.packageID == bundle.packageID)
        #expect(package.scope == .repository)
        #expect(package.schemaVersion == SharePackageModel.partialEnvironmentsSchemaVersion)
        #expect(package.flattenedItems.allSatisfy { $0.item.linkToken == nil })
        try SharePackageValidator.validate(package, mode: .payload)
        // The values are the bundle's buffers.
        #expect(package.repository.secrets[0].value == bundle.repositories[0].repository.secrets[0].value)
    }

    @Test func folderPackageIsASchemaThreeFolder() throws {
        let bundle = BundleFactory.sample()
        let package = try #require(bundle.folderPackage(for: bundle.folders[0].id))
        #expect(package.isFolder)
        #expect(package.folder?.name == "Mobile App")
        #expect(package.packageID == bundle.packageID)
        try SharePackageValidator.validate(package, mode: .payload)
    }

    @Test func aRepositoryPackageBecomesABundleWithItsIDSenderAndValues() throws {
        let package = PackageFactory.sample()
        let createdAt = Date(timeIntervalSince1970: 1_900_000_000)
        let bundle = ShareBundleModel(package: package, createdAt: createdAt, expiry: .default)
        #expect(bundle.packageID == package.packageID)
        #expect(bundle.sender == package.sender)
        #expect(bundle.producer == package.producer)
        #expect(bundle.createdAt == createdAt)
        #expect(bundle.expiresAt == ShareExpiryChoice.default.expiry(from: createdAt))
        #expect(bundle.repositories.map(\.repository) == [package.repository])
        #expect(bundle.repositories[0].destinations.isEmpty)
        #expect(bundle.folders.isEmpty)
        #expect(bundle.stages.isEmpty)
        try ShareBundleValidator.validate(bundle, mode: .payload)
        let json = try ShareBundleCoder.encode(bundle)
        defer { json.wipe() }
        guard case .bundle(let decoded) = try ShareDocumentCoder.open(json) else {
            Issue.record("Expected a bundle")
            return
        }
        #expect(decoded == bundle)
    }

    @Test func aFolderPackageBecomesABundleWithOneFolder() throws {
        let package = SharePackageModel.folder(
            named: "Mobile App",
            secrets: [BundleFactory.item("FIREBASE_API_KEY")],
            variables: [BundleFactory.item("APP_ENV", value: "staging")],
            createdAt: PackageFactory.createdAt,
            producer: ShareProducerModel(version: "1.0.0"),
            sender: ShareSenderModel(displayName: "Sam")
        )
        let bundle = ShareBundleModel(package: package, createdAt: PackageFactory.createdAt, expiry: .oneDay)
        #expect(bundle.repositories.isEmpty)
        #expect(bundle.folders.map(\.name) == ["Mobile App"])
        #expect(bundle.folders[0].secrets == package.repository.secrets)
        #expect(bundle.folders[0].variables == package.repository.variables)
        #expect(bundle.packageID == package.packageID)
        try ShareBundleValidator.validate(bundle, mode: .payload)
    }

    @Test func freshnessToleratesTheClockSkewOnly() throws {
        let bundle = BundleFactory.bundle(repositories: [BundleFactory.repository(BundleFactory.web)])
        let skew = Timeouts.shareClockSkew.timeInterval
        try bundle.checkFreshness(now: bundle.createdAt)
        try bundle.checkFreshness(now: bundle.expiresAt.addingTimeInterval(skew - 1))
        try bundle.checkFreshness(now: bundle.createdAt.addingTimeInterval(-skew + 1))
        #expect(throws: ShareError.expired) { try bundle.checkFreshness(now: bundle.expiresAt.addingTimeInterval(skew + 1)) }
        #expect(throws: ShareError.invalidPackage(.createdInFuture)) {
            try bundle.checkFreshness(now: bundle.createdAt.addingTimeInterval(-skew - 1))
        }
    }
}

// MARK: - Any document

@Suite("Share document coder")
struct ShareDocumentCoderTests {
    @Test func dispatchesOnSchemaVersion() throws {
        let package = PackageFactory.sample()
        guard case .package(let decodedPackage) = try ShareDocumentCoder.decode(try SharePackageCoder.encode(package)) else {
            Issue.record("Expected a package")
            return
        }
        #expect(decodedPackage == package)

        let bundle = BundleFactory.sample()
        guard case .bundle(let decodedBundle) = try ShareDocumentCoder.open(try ShareBundleCoder.encode(bundle)) else {
            Issue.record("Expected a bundle")
            return
        }
        #expect(decodedBundle == bundle)
    }

    @Test func undecodableInputIsInvalidFile() {
        for text in ["", "{}", "{\"schemaVersion\":\"4\"}", "{\"schemaVersion\":4}"] {
            #expect(throws: ShareError.invalidFile) { _ = try ShareDocumentCoder.decode(SecretBytes(utf8: text)) }
        }
    }

    @Test func openValidatesAndRejectsUnknownVersions() throws {
        var package = PackageFactory.sample()
        package.schemaVersion = 5
        #expect(throws: ShareError.invalidPackage(.unsupportedSchemaVersion(5))) {
            _ = try ShareDocumentCoder.open(try SharePackageCoder.encode(package))
        }
        var bundle = BundleFactory.sample()
        bundle.repositories[0].repository.secrets[0].linkToken = "not-a-uuid"
        #expect(throws: ShareError.invalidPackage(.invalidLinkToken)) {
            _ = try ShareDocumentCoder.open(try ShareBundleCoder.encode(bundle))
        }
    }

    @Test func olderSchemasStayWithoutLinks() throws {
        let text = try #require(try SharePackageCoder.encode(PackageFactory.sample()).utf8String())
        #expect(!text.contains("\"link\""))
        var package = PackageFactory.sample()
        package.repository.secrets[0].linkToken = BundleFactory.linkToken
        #expect(throws: ShareError.invalidPackage(.linkNotAllowed)) {
            try SharePackageValidator.validate(package, mode: .payload)
        }
    }
}
