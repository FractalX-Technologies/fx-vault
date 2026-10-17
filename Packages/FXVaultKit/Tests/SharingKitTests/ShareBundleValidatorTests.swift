import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// Every schema 4 rule (v0.9.0), one table row each.
@Suite("Share bundle validator")
struct ShareBundleValidatorTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let mode: SharePackageValidator.Mode
        let mutate: @Sendable (inout ShareBundleModel) -> Void
        let expected: SharePackageViolation

        init(
            _ name: String,
            mode: SharePackageValidator.Mode = .payload,
            _ expected: SharePackageViolation,
            _ mutate: @escaping @Sendable (inout ShareBundleModel) -> Void
        ) {
            self.name = name
            self.mode = mode
            self.expected = expected
            self.mutate = mutate
        }

        var testDescription: String {
            name
        }
    }

    private static let skew = Timeouts.shareClockSkew.timeInterval
    private static let longest = Timeouts.shareMaxExpiry.timeInterval

    private static func destination(
        _ target: DestinationTargetModel,
        stage: String? = "staging",
        secrets: [ShareItemModel] = [],
        variables: [ShareItemModel] = [],
        publicNames: [String] = []
    ) -> ShareDestinationModel {
        ShareDestinationModel(target: target, stage: stage, secrets: secrets, variables: variables, publicNames: publicNames)
    }

    static let cases: [Case] = [
        Case("unknown schema", .unsupportedSchema) { $0.schema = "other" },
        Case("schema version 3", .unsupportedSchemaVersion(3)) { $0.schemaVersion = 3 },
        Case("empty producer", .invalidProducer) { $0.producer = ShareProducerModel(app: "", version: "0.9.0") },
        Case("unsanitized sender", .invalidSenderName) { $0.sender = ShareSenderModel(displayName: "Sam\u{202E}") },
        Case("expires when created", .invalidExpiry) { $0.expiresAt = $0.createdAt },
        Case("expires before created", .invalidExpiry) { $0.expiresAt = $0.createdAt.addingTimeInterval(-1) },
        Case("expires after 30 days and the skew", .invalidExpiry) {
            $0.expiresAt = $0.createdAt.addingTimeInterval(longest + skew + 1)
        },
        Case("stage with spaces around", .invalidStage(.invalidName(.leadingOrTrailingWhitespace))) { $0.stages = [" staging"] },
        Case("stage twice", .duplicateStage) { $0.stages = ["staging", "Staging"] },
        Case("nothing in it", .emptyBundle) {
            $0.repositories = []
            $0.folders = []
        },
        Case("51 repositories", .tooManyRepositories(limit: 50)) { bundle in
            bundle.folders = []
            bundle.repositories = (0...Limits.maxShareRepositories).map { BundleFactory.repository("example-\($0)") }
        },
        Case("same repository twice", .duplicateRepository) {
            $0.repositories.append(BundleFactory.repository("Example-Web", owner: "Owner-A"))
        },
        Case("bad owner", .invalidOwner(.invalidCharacter)) { $0.repositories[0].repository.owner = "owner a" },
        Case("partial environment without items", .branchPolicyRequired) {
            $0.repositories[0].repository.environments[0].secrets = []
        },
        Case("bad Key Vault name", .invalidDestinationTarget(.invalidDestinationTarget(.keyVaultName))) {
            $0.repositories[1].destinations[0].target = .azureKeyVault(vaultName: "1-kv", tenantID: nil)
        },
        Case("untrimmed Key Vault name", .invalidDestinationTarget(.invalidDestinationTarget(.keyVaultName))) {
            $0.repositories[1].destinations[0].target = .azureKeyVault(vaultName: " kv-example-staging", tenantID: nil)
        },
        Case("bad Supabase reference", .invalidDestinationTarget(.invalidDestinationTarget(.supabaseProjectRef))) {
            $0.repositories[1].destinations[1].target = .supabase(projectRef: "ABC")
        },
        Case("bad destination stage", .invalidDestinationTarget(.invalidName(.leadingOrTrailingWhitespace))) {
            $0.repositories[1].destinations[0].stage = "staging "
        },
        Case("same target twice", .duplicateDestination) {
            $0.repositories[1].destinations.append(destination(.azureKeyVault(vaultName: "KV-Example-Staging", tenantID: nil)))
        },
        Case("33 destinations", .tooManyDestinations(limit: 32)) { bundle in
            bundle.repositories[1].destinations = (0...Limits.maxDestinationsPerRepository).map {
                destination(.azureKeyVault(vaultName: "kv-example-\($0)", tenantID: nil))
            }
        },
        Case("a variable in Key Vault", .invalidDestinationItem(.kindNotSupported)) {
            $0.repositories[1].destinations[0].variables = [BundleFactory.item("REGION")]
        },
        Case("Supabase's reserved prefix", .invalidDestinationItem(.invalidName(.reservedByProvider))) {
            $0.repositories[1].destinations[1].secrets = [BundleFactory.item("SUPABASE_URL")]
        },
        Case("a value above Key Vault's limit", .invalidDestinationItem(.valueTooLarge(limit: Limits.maxKeyVaultValueBytes))) {
            $0.repositories[1].destinations[0].secrets = [
                BundleFactory.item("BIG", value: String(repeating: "a", count: Limits.maxKeyVaultValueBytes + 1)),
            ]
        },
        Case("a value above GitHub's limit", .valueTooLarge(limit: Limits.maxValueBytes)) {
            $0.repositories[0].destinations[0].secrets = [
                BundleFactory.item("BIG", value: String(repeating: "a", count: Limits.maxValueBytes + 1)),
            ]
        },
        Case("a secret and a variable with one name", .duplicateDestinationItem) {
            $0.repositories[0].destinations[0].variables.append(BundleFactory.item("API_KEY"))
        },
        Case("a lowercase destination item", .invalidItemName(.notNormalized)) {
            $0.repositories[1].destinations[0].secrets = [BundleFactory.item("database_url")]
        },
        Case("1,001 destination items", .tooManyDestinationItems(limit: 1000)) { bundle in
            bundle.repositories[1].destinations[0].secrets = (0...Limits.maxDestinationItems).map { BundleFactory.item("KEY_\($0)") }
        },
        Case("a public name that is not an item", .invalidPublicName) {
            $0.repositories[0].destinations[0].publicNames = ["NEXT_PUBLIC_OTHER"]
        },
        Case("a public name twice", .invalidPublicName) {
            $0.repositories[0].destinations[0].publicNames = ["NEXT_PUBLIC_SITE_URL", "next_public_site_url"]
        },
        Case("a folder without a name", .invalidFolderName(.invalidName(.empty))) { $0.folders[0].name = "" },
        Case("two folders with one name", .duplicateFolder) {
            $0.folders.append(ShareBundleFolderModel(name: "mobile app", secrets: [BundleFactory.item("OTHER")]))
        },
        Case("a folder item without a value", .valueStateMismatch) {
            $0.folders[0].secrets = [BundleFactory.item("FIREBASE_KEY", value: nil)]
        },
        Case("a value in a manifest", mode: .manifest, .valueInManifest) { _ in },
        Case("an entry id twice", .duplicateEntryID) {
            $0.repositories[1].destinations[0].secrets[0].id = $0.repositories[0].repository.secrets[0].id
        },
        Case("a link used once", .invalidLinkToken) {
            $0.repositories[0].destinations[0].secrets[0].linkToken = nil
        },
        Case("a link that is not a UUID", .invalidLinkToken) {
            $0.repositories[0].repository.secrets[0].linkToken = "link-1"
            $0.repositories[0].destinations[0].secrets[0].linkToken = "link-1"
        },
        Case("an uppercase link", .invalidLinkToken) {
            let token = BundleFactory.linkToken.uppercased()
            $0.repositories[0].repository.secrets[0].linkToken = token
            $0.repositories[0].destinations[0].secrets[0].linkToken = token
        },
    ]

    @Test(arguments: cases)
    func rejects(_ testCase: Case) {
        var bundle = BundleFactory.sample()
        testCase.mutate(&bundle)
        #expect(ShareBundleValidator.violation(in: bundle, mode: testCase.mode) == testCase.expected)
        #expect(throws: ShareError.invalidPackage(testCase.expected)) {
            try ShareBundleValidator.validate(bundle, mode: testCase.mode)
        }
    }

    @Test func acceptsTheSampleAndItsManifest() throws {
        let bundle = BundleFactory.sample()
        try ShareBundleValidator.validate(bundle, mode: .payload)
        try ShareBundleValidator.validate(bundle.manifest(), mode: .manifest)
    }

    @Test func acceptsAFolderOnlyBundleAndTheLongestExpiry() throws {
        var bundle = BundleFactory.bundle(
            folders: [ShareBundleFolderModel(name: "Mobile App", secrets: [BundleFactory.item("FIREBASE_KEY")])],
            stages: [],
            expiry: .thirtyDays
        )
        try ShareBundleValidator.validate(bundle, mode: .payload)
        bundle.expiresAt = bundle.createdAt.addingTimeInterval(Self.longest + Self.skew)
        try ShareBundleValidator.validate(bundle, mode: .payload)
    }

    @Test func acceptsFiftyRepositoriesAndValuesUpToEachProvidersLimit() throws {
        var bundle = BundleFactory.bundle(repositories: (1...Limits.maxShareRepositories).map { BundleFactory.repository("example-\($0)") })
        try ShareBundleValidator.validate(bundle, mode: .payload)
        bundle.repositories[0].destinations = [
            Self.destination(
                BundleFactory.keyVault,
                secrets: [BundleFactory.item("BIG", value: String(repeating: "a", count: Limits.maxKeyVaultValueBytes))]
            ),
            Self.destination(
                BundleFactory.vercelPreview,
                secrets: [BundleFactory.item("BIG", value: String(repeating: "a", count: Limits.maxValueBytes))]
            ),
        ]
        try ShareBundleValidator.validate(bundle, mode: .payload)
    }

    @Test func aDestinationItemWithoutAValueIsAccepted() throws {
        var bundle = BundleFactory.sample()
        bundle.repositories[1].destinations[1].secrets = [BundleFactory.item("STRIPE_KEY", value: nil)]
        try ShareBundleValidator.validate(bundle, mode: .payload)
    }
}
