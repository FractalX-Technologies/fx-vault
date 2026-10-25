import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// "Share any combination" (v0.2.0): schema v2 partial environments, the lowest-version rule,
/// round trips, filtering, per-scope counts, 0.1.x compatibility and the planner's handling of
/// packages that carry only part of a repository.
@Suite("Share subsets")
struct ShareSubsetPackageTests {
    private typealias Planner = ShareImportPlannerTests

    private func json(_ package: SharePackageModel) throws -> [String: Any] {
        let bytes = try SharePackageCoder.encode(package)
        let data = bytes.withUnsafeBytes { Data($0) }
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func environments(_ document: [String: Any]) throws -> [[String: Any]] {
        let repository = try #require(document["repository"] as? [String: Any])
        return try #require(repository["environments"] as? [[String: Any]])
    }

    /// Repository-level items plus one whole environment, as the tree builds it.
    private static func repositoryLevelAndOneEnvironment() -> SharePackageModel {
        PackageFactory.package(
            secrets: [PackageFactory.item("API_KEY")],
            variables: [PackageFactory.item("REGION", value: "eu-west-1")],
            environments: [
                PackageFactory.environment(
                    "staging",
                    policy: ShareBranchPolicyModel(type: .custom, patterns: [ShareBranchPatternModel(name: "main", type: .branch)]),
                    secrets: [PackageFactory.item("DB_PASSWORD")],
                    variables: [PackageFactory.item("LOG_LEVEL", value: "debug")]
                ),
            ]
        )
    }

    /// Individual items only: one repository-level secret and one item of each of two
    /// environments (partial environments).
    private static func itemsOnly() -> SharePackageModel {
        PackageFactory.package(
            secrets: [PackageFactory.item("API_KEY")],
            environments: [
                PackageFactory.partialEnvironment("staging", secrets: [PackageFactory.item("DB_PASSWORD")]),
                PackageFactory.partialEnvironment("production", variables: [PackageFactory.item("LOG_LEVEL", value: "warn")]),
            ]
        )
    }

    // MARK: - Round trips

    @Test func repositoryLevelPlusOneEnvironmentRoundTripsAsSchemaV1() throws {
        let package = Self.repositoryLevelAndOneEnvironment()
        #expect(package.schemaVersion == SharePackageModel.wholeEnvironmentsSchemaVersion)
        #expect(SharePackageValidator.violation(in: package, mode: .payload) == nil)

        let document = try json(package)
        #expect(document["schemaVersion"] as? Int == 1)
        let policy = try #require(try environments(document).first?["deploymentBranchPolicy"] as? [String: Any])
        #expect(policy["type"] as? String == "custom")

        let decoded = try SharePackageCoder.decode(try SharePackageCoder.encode(package))
        #expect(decoded == package)
        #expect(SharePackageValidator.violation(in: decoded, mode: .payload) == nil)
        #expect(decoded.repository.environments.first?.includesBranchPolicy == true)
    }

    @Test func itemsOnlyRoundTripsAsSchemaV2WithNullPolicies() throws {
        let package = Self.itemsOnly()
        #expect(package.schemaVersion == SharePackageModel.partialEnvironmentsSchemaVersion)

        let document = try json(package)
        #expect(document["schemaVersion"] as? Int == 2)
        let encoded = try environments(document)
        #expect(encoded.count == 2)
        #expect(encoded.allSatisfy { $0["deploymentBranchPolicy"] is NSNull })

        let decoded = try SharePackageCoder.decode(try SharePackageCoder.encode(package))
        #expect(decoded == package)
        #expect(decoded.repository.environments.allSatisfy { !$0.includesBranchPolicy })
        #expect(SharePackageValidator.violation(in: decoded, mode: .payload) == nil)
        #expect(SharePackageValidator.violation(in: decoded.manifest(), mode: .manifest) == nil)
    }

    @Test func anAbsentPolicyKeyDecodesAsPartial() throws {
        var text = try #require(try SharePackageCoder.encode(Self.itemsOnly()).utf8String())
        text = text.replacingOccurrences(of: "\"deploymentBranchPolicy\":null,", with: "")
        let decoded = try SharePackageCoder.decode(SecretBytes(utf8: text))
        #expect(decoded.repository.environments.allSatisfy { !$0.includesBranchPolicy })
        #expect(SharePackageValidator.violation(in: decoded, mode: .payload) == nil)
    }

    @Test func aPartialEnvironmentIsRejectedWhenLabelledV1() throws {
        var package = Self.itemsOnly()
        package.schemaVersion = SharePackageModel.wholeEnvironmentsSchemaVersion
        let decoded = try SharePackageCoder.decode(try SharePackageCoder.encode(package))
        #expect(throws: ShareError.invalidPackage(.branchPolicyRequired)) {
            try SharePackageValidator.validate(decoded, mode: .payload)
        }
    }

    // MARK: - Lowest version

    @Test func requiredSchemaVersionIsTheLowestThatHoldsTheContents() {
        #expect(SharePackageModel.requiredSchemaVersion(for: PackageFactory.sample().repository) == 1)
        #expect(SharePackageModel.requiredSchemaVersion(for: PackageFactory.package().repository) == 1)
        #expect(SharePackageModel.requiredSchemaVersion(for: Self.itemsOnly().repository) == 2)
        #expect(SharePackageModel.supportedSchemaVersions == 1...3)
        #expect(SharePackageModel.repositorySchemaVersions == 1...2)
        #expect(SharePackageModel.currentSchemaVersion == SharePackageModel.folderSchemaVersion)
    }

    // MARK: - Counts

    @Test func contentSummaryCountsPerScopeWithoutValues() {
        let package = PackageFactory.package(
            secrets: [PackageFactory.item("A"), PackageFactory.item("B")],
            variables: [PackageFactory.item("C", value: "c")],
            environments: [
                PackageFactory.environment("staging", secrets: [PackageFactory.item("S")], variables: [PackageFactory.item("V", value: "v")]),
                PackageFactory.partialEnvironment("production", variables: [PackageFactory.item("P", value: "p")]),
            ]
        )
        let summary = package.contentSummary
        #expect(summary.repositoryLevel == ShareItemCountModel(secrets: 2, variables: 1))
        #expect(summary.environments == [
            ShareEnvironmentSummaryModel(name: "staging", counts: ShareItemCountModel(secrets: 1, variables: 1), includesBranchPolicy: true),
            ShareEnvironmentSummaryModel(name: "production", counts: ShareItemCountModel(secrets: 0, variables: 1), includesBranchPolicy: false),
        ])
        #expect(summary.itemCount == package.itemCount)
        #expect(!String(describing: summary).contains("value-"))
    }

    // MARK: - 0.1.x compatibility

    @Test func aPackageWrittenByVersion01StillDecodesValidatesAndPlans() throws {
        // Written by FX Vault 0.1.1 (ShareExportBuilder, single environment secret).
        let json = try Fixtures.data("item-v1-0.1.1.json")
        let package = try SharePackageCoder.decode(SecretBytes(json))
        defer { package.wipeValues() }
        #expect(package.schemaVersion == 1)
        #expect(package.scope == .secret)
        #expect(package.producer.version == "0.1.1")
        try SharePackageValidator.validate(package, mode: .payload)
        try SharePackageValidator.validate(package.manifest(), mode: .manifest)
        let environment = try #require(package.repository.environments.first)
        #expect(environment.deploymentBranchPolicy == ShareBranchPolicyModel(
            type: .custom,
            patterns: [ShareBranchPatternModel(name: "release/*", type: .branch)]
        ))

        // 0.1.x semantics are kept: its policy is offered as a "differs" row (Keep mine).
        var local = Planner.Local(githubID: package.repository.githubRepoID, owner: package.repository.owner, name: package.repository.name)
        local.addEnvironment("production")
        let plan = try ShareImportPlanner.plan(package, mode: .payload, local: local.state, fingerprint: Planner.fingerprinter)
        let planned = try #require(plan.environments.first)
        #expect(planned.includesBranchPolicy)
        #expect(planned.policyDifference?.decision == .keepMine)
        #expect(planned.policyDifference?.isWidening == false)
        #expect(planned.items.map(\.key.name) == ["FXV_S2"])
        #expect(planned.items.first?.chip == .new)
    }

    // MARK: - Planner

    @Test func aPartialEnvironmentNeverOffersAPolicyRow() throws {
        let package = PackageFactory.package(environments: [
            PackageFactory.partialEnvironment("staging", secrets: [PackageFactory.item("KEY", value: "v")]),
        ])
        var local = Planner.Local()
        local.addEnvironment("staging", policy: .protectedBranches)
        let plan = try Planner.plan(package, local)
        let environment = try #require(plan.environments.first)
        #expect(environment.action == .useExisting)
        #expect(!environment.includesBranchPolicy)
        #expect(environment.incomingPolicy == nil)
        #expect(environment.policyDifference == nil)
        #expect(environment.items.first?.chip == .new)
        #expect(plan.pendingChangeCount == 1)
        #expect(throws: ShareError.importActionNotAllowed) {
            var editable = plan
            try editable.setPolicyDecision(.useIncoming, forEnvironment: environment.id, wideningConfirmed: true)
        }
    }

    @Test func aMissingPartialEnvironmentIsCreatedPendingUnlessGitHubHasIt() throws {
        let package = PackageFactory.package(environments: [
            PackageFactory.partialEnvironment("staging", variables: [PackageFactory.item("LEVEL", value: "1")]),
        ])
        let plan = try Planner.plan(package, Planner.Local())
        #expect(plan.environments.first?.action == .create(pending: true))
        #expect(plan.environments.first?.incomingPolicy == nil)

        var listed = Planner.Local()
        listed.remote = ShareRemoteSnapshotModel(environmentNames: ["staging"], items: [])
        #expect(try Planner.plan(package, listed).environments.first?.action == .create(pending: false))
    }

    @Test func onlyWholeEnvironmentsCountAsOlderThanLocalChanges() throws {
        var local = Planner.Local()
        let later = PackageFactory.createdAt.addingTimeInterval(1)
        local.environments.append(EnvironmentModel(
            repositoryID: local.repository.id,
            name: "staging",
            branchPolicy: .all,
            createdAt: Planner.earlier,
            updatedAt: later
        ))
        let partial = PackageFactory.package(environments: [
            PackageFactory.partialEnvironment("staging", secrets: [PackageFactory.item("KEY")]),
        ])
        #expect(try Planner.plan(partial, local).replayWarnings.isEmpty)

        let whole = PackageFactory.package(environments: [
            PackageFactory.environment("staging", secrets: [PackageFactory.item("KEY")]),
        ])
        #expect(try Planner.plan(whole, local).replayWarnings == [.olderThanLocalChanges])
    }

    @Test func aPartialPackagePlansOnlyWhatItCarries() throws {
        var local = Planner.Local()
        let staging = local.addEnvironment("staging")
        local.addItem("OTHER", value: "mine", environment: staging)
        local.addItem("REPO_ONLY", value: "mine")
        let package = PackageFactory.package(environments: [
            PackageFactory.partialEnvironment("staging", secrets: [PackageFactory.item("KEY", value: "v")]),
        ])
        let plan = try Planner.plan(package, local)
        #expect(plan.repositoryItems.isEmpty)
        #expect(plan.allItems.map(\.key.name) == ["KEY"])
        #expect(plan.changedItems.map(\.key.name) == ["KEY"])
    }
}
