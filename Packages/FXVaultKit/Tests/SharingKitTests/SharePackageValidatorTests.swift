import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// §9.3 `SharePackageValidator` table.
@Suite("Share package validator")
struct SharePackageValidatorTests {
    typealias Mutation = @Sendable (inout SharePackageModel) -> Void

    struct Case: Sendable, CustomTestStringConvertible {
        let label: String
        let mutate: Mutation
        let expected: SharePackageViolation
        var mode: SharePackageValidator.Mode = .payload

        var testDescription: String { label }
    }

    static func setEnvironmentName(_ name: String) -> Mutation {
        { $0.repository.environments[0].name = name }
    }

    static func setSecretName(_ name: String) -> Mutation {
        { $0.repository.secrets[0].name = name }
    }

    static let rejected: [Case] = [
        // Header
        Case(label: "schema", mutate: { $0.schema = "io.example.share" }, expected: .unsupportedSchema),
        Case(label: "schema version", mutate: { $0.schemaVersion = 2 }, expected: .unsupportedSchemaVersion(2)),
        Case(label: "empty producer", mutate: { $0.producer.app = "" }, expected: .invalidProducer),
        Case(label: "producer bidi", mutate: { $0.producer.version = "1.0\u{202E}" }, expected: .invalidProducer),
        Case(label: "sender bidi", mutate: { $0.sender.displayName = "Bry\u{202E}an" }, expected: .invalidSenderName),
        Case(label: "sender zero width", mutate: { $0.sender.displayName = "Bry\u{200B}an" }, expected: .invalidSenderName),
        Case(label: "sender too long", mutate: { $0.sender.displayName = String(repeating: "a", count: 64) }, expected: .invalidSenderName),
        // Host, owner, repo
        Case(label: "host", mutate: { $0.repository.host = "github.example.com" }, expected: .invalidHost),
        Case(label: "host case", mutate: { $0.repository.host = "GitHub.com" }, expected: .invalidHost),
        Case(label: "owner leading hyphen", mutate: { $0.repository.owner = "-octo" }, expected: .invalidOwner(.invalidFirstCharacter)),
        Case(label: "owner slash", mutate: { $0.repository.owner = "octo/../x" }, expected: .invalidOwner(.invalidCharacter)),
        Case(label: "owner too long", mutate: { $0.repository.owner = String(repeating: "a", count: 40) }, expected: .invalidOwner(.tooLong(maxLength: 39))),
        Case(label: "owner empty", mutate: { $0.repository.owner = "" }, expected: .invalidOwner(.empty)),
        Case(label: "repo dot", mutate: { $0.repository.name = "." }, expected: .invalidRepositoryName(.dotName)),
        Case(label: "repo dot dot", mutate: { $0.repository.name = ".." }, expected: .invalidRepositoryName(.dotName)),
        Case(label: "repo .git", mutate: { $0.repository.name = "service.GIT" }, expected: .invalidRepositoryName(.gitSuffix)),
        Case(label: "repo id", mutate: { $0.repository.githubRepoID = "R_abc?x" }, expected: .invalidGitHubRepoID),
        Case(label: "repo id empty", mutate: { $0.repository.githubRepoID = "" }, expected: .invalidGitHubRepoID),
        // Environments
        Case(label: "env dot dot", mutate: setEnvironmentName(".."), expected: .invalidEnvironmentName(.invalidPathSegment(.dotSegment))),
        Case(label: "env encoded dots", mutate: setEnvironmentName("%2E%2E"), expected: .invalidEnvironmentName(.invalidPathSegment(.encodedDotSegment))),
        Case(label: "env slash", mutate: setEnvironmentName("prod/eu"), expected: .invalidEnvironmentName(.invalidPathSegment(.separator))),
        Case(label: "env bidi", mutate: setEnvironmentName("prod\u{202E}"), expected: .invalidEnvironmentName(.invalidName(.bidiCharacter))),
        Case(label: "env LRM", mutate: setEnvironmentName("prod\u{200E}"), expected: .invalidEnvironmentName(.invalidName(.bidiCharacter))),
        Case(label: "env isolate", mutate: setEnvironmentName("pr\u{2066}od"), expected: .invalidEnvironmentName(.invalidName(.bidiCharacter))),
        Case(label: "env zero width", mutate: setEnvironmentName("pr\u{200B}od"), expected: .invalidEnvironmentName(.invalidName(.zeroWidthCharacter))),
        Case(label: "env BOM", mutate: setEnvironmentName("\u{FEFF}prod"), expected: .invalidEnvironmentName(.invalidName(.zeroWidthCharacter))),
        Case(label: "env C0", mutate: setEnvironmentName("prod\u{0007}"), expected: .invalidEnvironmentName(.invalidName(.controlCharacter))),
        Case(label: "env C1", mutate: setEnvironmentName("prod\u{0085}"), expected: .invalidEnvironmentName(.invalidName(.controlCharacter))),
        Case(label: "env leading space", mutate: setEnvironmentName(" prod"), expected: .invalidEnvironmentName(.invalidName(.leadingOrTrailingWhitespace))),
        Case(label: "env trailing NBSP", mutate: setEnvironmentName("prod\u{00A0}"), expected: .invalidEnvironmentName(.invalidName(.leadingOrTrailingWhitespace))),
        Case(label: "env not NFC", mutate: setEnvironmentName("Produccio\u{0301}n"), expected: .invalidEnvironmentName(.invalidName(.notNormalized))),
        Case(label: "env empty", mutate: setEnvironmentName(""), expected: .invalidEnvironmentName(.invalidName(.empty))),
        Case(
            label: "env duplicate by fold key",
            mutate: { $0.repository.environments.append(PackageFactory.environment("PRODUCCIÓN")) },
            expected: .duplicateEnvironment
        ),
        // Item names and uniqueness
        Case(label: "item lowercase", mutate: setSecretName("api_key"), expected: .invalidItemName(.notNormalized)),
        Case(label: "item GITHUB_", mutate: setSecretName("GITHUB_TOKEN"), expected: .invalidItemName(.reservedPrefix)),
        Case(label: "item leading digit", mutate: setSecretName("1KEY"), expected: .invalidItemName(.leadingDigit)),
        Case(label: "item hyphen", mutate: setSecretName("API-KEY"), expected: .invalidItemName(.invalidCharacter)),
        Case(label: "item dot dot", mutate: setSecretName(".."), expected: .invalidItemName(.invalidCharacter)),
        Case(label: "item zero width", mutate: setSecretName("API\u{200B}KEY"), expected: .invalidItemName(.zeroWidthCharacter)),
        Case(
            label: "duplicate secret",
            mutate: { $0.repository.secrets.append(PackageFactory.item("API_KEY")) },
            expected: .duplicateItem(kind: .secret, level: .repository)
        ),
        Case(
            label: "duplicate environment variable",
            mutate: { $0.repository.environments[0].variables.append(PackageFactory.item("LOG_LEVEL")) },
            expected: .duplicateItem(kind: .variable, level: .environment)
        ),
        Case(
            label: "duplicate entry id",
            mutate: { $0.repository.variables[0].id = $0.repository.secrets[0].id },
            expected: .duplicateEntryID
        ),
        // Counts
        Case(
            label: "101 repository secrets",
            mutate: { $0.repository.secrets = (0...100).map { PackageFactory.item("S_\($0)") } },
            expected: .tooManyItems(kind: .secret, level: .repository, limit: 100)
        ),
        Case(
            label: "501 repository variables",
            mutate: { $0.repository.variables = (0...500).map { PackageFactory.item("V_\($0)", value: "x") } },
            expected: .tooManyItems(kind: .variable, level: .repository, limit: 500)
        ),
        Case(
            label: "101 environment secrets",
            mutate: { $0.repository.environments[0].secrets = (0...100).map { PackageFactory.item("S_\($0)") } },
            expected: .tooManyItems(kind: .secret, level: .environment, limit: 100)
        ),
        Case(
            label: "101 environment variables",
            mutate: { $0.repository.environments[0].variables = (0...100).map { PackageFactory.item("V_\($0)", value: "x") } },
            expected: .tooManyItems(kind: .variable, level: .environment, limit: 100)
        ),
        // Values
        Case(
            label: "value over 48,000 bytes",
            mutate: { $0.repository.secrets[0].value = SecretBytes(utf8: String(repeating: "a", count: 48_001)) },
            expected: .valueTooLarge(limit: 48_000)
        ),
        Case(
            label: "value only newlines",
            mutate: { $0.repository.secrets[0].value = SecretBytes(utf8: "\r\n\n") },
            expected: .emptyValue
        ),
        Case(
            label: "value not UTF-8",
            mutate: { $0.repository.secrets[0].value = SecretBytes(copying: [0xFF, 0xFE]) },
            expected: .valueNotUTF8
        ),
        Case(
            label: "present without value",
            mutate: { $0.repository.secrets[0].value = nil },
            expected: .valueStateMismatch
        ),
        Case(
            label: "missing with value",
            mutate: { $0.repository.secrets[1].value = SecretBytes(utf8: "x") },
            expected: .valueStateMismatch
        ),
        Case(
            label: "value in manifest",
            mutate: { _ in },
            expected: .valueInManifest,
            mode: .manifest
        ),
        // Patterns
        Case(
            label: "patterns without custom",
            mutate: { $0.repository.environments[0].deploymentBranchPolicy.type = .protected },
            expected: .patternsWithoutCustomPolicy
        ),
        Case(
            label: "51 patterns",
            mutate: {
                $0.repository.environments[0].deploymentBranchPolicy.patterns = (0...50).map {
                    ShareBranchPatternModel(name: "release/\($0)", type: .branch)
                }
            },
            expected: .tooManyPatterns(limit: 50)
        ),
        Case(
            label: "pattern too long",
            mutate: {
                $0.repository.environments[0].deploymentBranchPolicy.patterns = [
                    ShareBranchPatternModel(name: String(repeating: "a", count: 256), type: .branch),
                ]
            },
            expected: .invalidPattern(.tooLong(maxLength: 255))
        ),
        Case(
            label: "pattern empty",
            mutate: { $0.repository.environments[0].deploymentBranchPolicy.patterns = [ShareBranchPatternModel(name: "", type: .tag)] },
            expected: .invalidPattern(.empty)
        ),
        Case(
            label: "pattern bidi",
            mutate: { $0.repository.environments[0].deploymentBranchPolicy.patterns = [ShareBranchPatternModel(name: "ma\u{202E}in", type: .branch)] },
            expected: .invalidPattern(.bidiCharacter)
        ),
        Case(
            label: "pattern control",
            mutate: { $0.repository.environments[0].deploymentBranchPolicy.patterns = [ShareBranchPatternModel(name: "main\n", type: .branch)] },
            expected: .invalidPattern(.controlCharacter)
        ),
        Case(
            label: "duplicate pattern",
            mutate: {
                let pattern = ShareBranchPatternModel(name: "main", type: .branch)
                $0.repository.environments[0].deploymentBranchPolicy.patterns = [pattern, pattern]
            },
            expected: .duplicatePattern
        ),
        // Scope rules
        Case(label: "secret scope with many items", mutate: { $0.scope = .secret }, expected: .scopeMismatch(.secret)),
        Case(label: "environment scope with repo items", mutate: { $0.scope = .environment }, expected: .scopeMismatch(.environment)),
    ]

    @Test(arguments: rejected)
    func rejects(_ testCase: Case) {
        var package = PackageFactory.sample()
        testCase.mutate(&package)
        #expect(SharePackageValidator.violation(in: package, mode: testCase.mode) == testCase.expected)
        #expect(throws: ShareError.invalidPackage(testCase.expected)) {
            try SharePackageValidator.validate(package, mode: testCase.mode)
        }
    }

    @Test func acceptsTheSampleInBothModes() {
        let package = PackageFactory.sample()
        #expect(SharePackageValidator.violation(in: package, mode: .payload) == nil)
        #expect(SharePackageValidator.violation(in: package.manifest(), mode: .manifest) == nil)
    }

    @Test func acceptsLimitsExactly() {
        var package = PackageFactory.sample()
        package.repository.secrets = (0..<100).map { PackageFactory.item("S_\($0)") }
        package.repository.variables = (0..<500).map { PackageFactory.item("V_\($0)", value: "x") }
        package.repository.environments[0].deploymentBranchPolicy.patterns = (0..<50).map {
            ShareBranchPatternModel(name: "release/*/\($0)", type: .branch)
        }
        package.repository.environments[0].secrets[0].value = SecretBytes(utf8: String(repeating: "a", count: 48_000) + "\n")
        #expect(SharePackageValidator.violation(in: package, mode: .payload) == nil)
    }

    @Test func acceptsValidScopes() {
        let secret = PackageFactory.package(scope: .secret, secrets: [PackageFactory.item("ONLY")])
        #expect(SharePackageValidator.violation(in: secret, mode: .payload) == nil)
        let environmentSecret = PackageFactory.package(
            scope: .secret,
            environments: [PackageFactory.environment("staging", variables: [PackageFactory.item("ONLY", value: "1")])]
        )
        #expect(SharePackageValidator.violation(in: environmentSecret, mode: .payload) == nil)
        let environment = PackageFactory.package(
            scope: .environment,
            environments: [PackageFactory.environment("staging")]
        )
        #expect(SharePackageValidator.violation(in: environment, mode: .payload) == nil)
        let twoEnvironments = PackageFactory.package(
            scope: .environment,
            environments: [PackageFactory.environment("a"), PackageFactory.environment("b")]
        )
        #expect(SharePackageValidator.violation(in: twoEnvironments, mode: .payload) == .scopeMismatch(.environment))
        let emptySecret = PackageFactory.package(scope: .secret)
        #expect(SharePackageValidator.violation(in: emptySecret, mode: .payload) == .scopeMismatch(.secret))
    }

    @Test func secretAndVariableMayShareANameInOneScope() {
        let package = PackageFactory.package(
            secrets: [PackageFactory.item("TOKEN")],
            variables: [PackageFactory.item("TOKEN", value: "public")]
        )
        #expect(SharePackageValidator.violation(in: package, mode: .payload) == nil)
    }

    @Test func missingRepoIDIsAllowed() {
        let package = PackageFactory.package(secrets: [PackageFactory.item("A")], githubRepoID: nil)
        #expect(SharePackageValidator.violation(in: package, mode: .payload) == nil)
    }
}
