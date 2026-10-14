import Testing
import VaultCore
@testable import EnvTools

@Suite("KeyNormalizer")
struct KeyNormalizerTests {
    @Test(
        "status and proposed key",
        arguments: [
            ("API_URL", KeyNormalizationModel.Status.valid, "API_URL" as String?),
            ("api_url", .uppercased, "API_URL"),
            ("Mixed_Case1", .uppercased, "MIXED_CASE1"),
            ("api-url", .needsFix(.invalidCharacter), "API_URL"),
            ("app.name", .needsFix(.invalidCharacter), "APP_NAME"),
            ("my key", .needsFix(.invalidCharacter), "MY_KEY"),
            ("Producción", .needsFix(.invalidCharacter), "PRODUCCION"),
            ("1password", .needsFix(.leadingDigit), "_1PASSWORD"),
            ("GITHUB_TOKEN", .needsFix(.reservedPrefix), "GH_TOKEN"),
            ("github_token", .needsFix(.reservedPrefix), "GH_TOKEN"),
            ("---", .needsFix(.invalidCharacter), nil),
            ("", .needsFix(.empty), nil),
        ]
    )
    func normalize(key: String, status: KeyNormalizationModel.Status, proposed: String?) {
        let result = KeyNormalizer.normalize(key)
        #expect(result.originalKey == key)
        #expect(result.status == status)
        #expect(result.proposedKey == proposed)
    }

    @Test func reviewIsNeededOnlyForFixes() {
        #expect(!KeyNormalizer.normalize("API_URL").needsReview)
        #expect(!KeyNormalizer.normalize("api_url").needsReview)
        #expect(KeyNormalizer.normalize("api-url").needsReview)
    }

    @Test func proposedKeysAreValidGitHubNames() {
        for key in ["api-url", "app.name", "1password", "GITHUB_TOKEN", "Producción", "x y z"] {
            let proposed = KeyNormalizer.normalize(key).proposedKey
            #expect(proposed.map(GitHubNameValidator.isValid) == true, "\(key) → \(String(describing: proposed))")
        }
    }

    @Test func uniqueKeyKeepsAFreeName() {
        #expect(KeyNormalizer.uniqueKey(from: "API_URL", avoiding: []) == "API_URL")
        #expect(KeyNormalizer.uniqueKey(from: "api_url", avoiding: ["OTHER"]) == "API_URL")
    }

    @Test func uniqueKeyAddsTheFirstFreeSuffix() {
        #expect(KeyNormalizer.uniqueKey(from: "API_URL", avoiding: ["API_URL"]) == "API_URL_2")
        #expect(KeyNormalizer.uniqueKey(from: "API_URL", avoiding: ["API_URL", "API_URL_2"]) == "API_URL_3")
    }

    @Test func uniqueKeyShortensLongNames() throws {
        let long = String(repeating: "A", count: Limits.maxConfigNameLength)
        let unique = try #require(KeyNormalizer.uniqueKey(from: long, avoiding: [long]))
        #expect(unique.utf8.count == Limits.maxConfigNameLength)
        #expect(unique.hasSuffix("_2"))
    }

    @Test func uniqueKeyGivesUpWhenEverySuffixIsTaken() {
        let suffixes = (EnvToolsLimits.firstUniqueKeySuffix...EnvToolsLimits.maxUniqueKeySuffix).map { "K_\($0)" }
        let taken = Set(["K"] + suffixes)
        #expect(KeyNormalizer.uniqueKey(from: "K", avoiding: taken) == nil)
    }
}
