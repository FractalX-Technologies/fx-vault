import Testing
import VaultCore

@Suite("GitHubNameValidator")
struct GitHubNameValidatorTests {
    @Test(arguments: [
        ("API_KEY", "API_KEY"),
        ("api_key", "API_KEY"),
        ("Sentry_Dsn", "SENTRY_DSN"),
        ("_PRIVATE", "_PRIVATE"),
        ("_1PASSWORD", "_1PASSWORD"),
        ("A1", "A1"),
        ("X", "X"),
        ("_", "_"),
        ("GITHUB", "GITHUB"),
        ("GITHUBTOKEN", "GITHUBTOKEN"),
        ("MY_GITHUB_TOKEN", "MY_GITHUB_TOKEN"),
    ])
    func acceptsAndUppercases(input: String, expected: String) throws {
        #expect(try GitHubNameValidator.validate(input) == expected)
        #expect(GitHubNameValidator.foldKey(input) == expected)
    }

    @Test(arguments: [
        ("", NameRule.empty),
        ("1PASSWORD", .leadingDigit),
        ("9", .leadingDigit),
        ("GITHUB_TOKEN", .reservedPrefix),
        ("github_token", .reservedPrefix),
        ("Github_Sha", .reservedPrefix),
        ("GITHUB_", .reservedPrefix),
        ("FXVAULT_SPACE", .reservedName),
        ("fxvault_space", .reservedName),
        ("API KEY", .invalidCharacter),
        ("API-KEY", .invalidCharacter),
        ("API.KEY", .invalidCharacter),
        ("PRODUCCIÓN", .invalidCharacter),
        ("straße", .invalidCharacter),
        ("ＡＰＩ", .invalidCharacter),
        ("KEY\n", .controlCharacter),
        ("KEY\u{202E}", .bidiCharacter),
        ("KEY\u{200B}", .zeroWidthCharacter),
        (String(repeating: "A", count: Limits.maxConfigNameLength + 1),
         .tooLong(maxLength: Limits.maxConfigNameLength)),
    ])
    func rejects(input: String, rule: NameRule) {
        #expect(GitHubNameValidator.violation(in: input) == rule)
        #expect(throws: ValidationError.invalidName(rule)) {
            try GitHubNameValidator.validate(input)
        }
    }

    @Test func acceptsTheMaximumLength() {
        let name = String(repeating: "A", count: Limits.maxConfigNameLength)
        #expect(GitHubNameValidator.isValid(name))
    }

    @Test(arguments: [
        ("api key", "API_KEY"),
        ("my-secret.value", "MY_SECRET_VALUE"),
        ("  padded  ", "PADDED"),
        ("1password", "_1PASSWORD"),
        ("GITHUB_TOKEN", "GH_TOKEN"),
        ("github-token", "GH_TOKEN"),
        ("Producción", "PRODUCCION"),
        ("clé d'API", "CLE_D_API"),
        ("--key--", "KEY"),
        ("a\u{200B}b", "AB"),
    ])
    func suggestsAFix(input: String, expected: String) {
        let fix = GitHubNameValidator.suggestedFix(for: input)
        #expect(fix == expected)
        if let fix {
            #expect(GitHubNameValidator.isValid(fix))
        }
    }

    @Test(arguments: ["API_KEY", "api_key"])
    func noFixForValidNames(input: String) {
        #expect(GitHubNameValidator.suggestedFix(for: input) == nil)
    }

    @Test(arguments: ["", "日本", "---", "\u{200B}"])
    func noFixWhenNothingUsableRemains(input: String) {
        #expect(GitHubNameValidator.suggestedFix(for: input) == nil)
    }

    @Test func fixIsTruncatedToTheLimit() throws {
        let long = String(repeating: "a-", count: Limits.maxConfigNameLength)
        let fix = try #require(GitHubNameValidator.suggestedFix(for: long))
        #expect(fix.utf8.count == Limits.maxConfigNameLength)
        #expect(GitHubNameValidator.isValid(fix))
    }

    @Test func availabilityComparesCaseInsensitively() throws {
        let taken: Set = [GitHubNameValidator.foldKey("API_KEY")]
        let reserved: Set = [GitHubNameValidator.foldKey("OLD_NAME")]
        #expect(throws: ValidationError.duplicateName) {
            try GitHubNameValidator.checkAvailability(of: "api_key", takenKeys: taken)
        }
        #expect(throws: ValidationError.nameReservedByPendingChange) {
            try GitHubNameValidator.checkAvailability(
                of: "old_name",
                takenKeys: taken,
                reservedKeys: reserved
            )
        }
        try GitHubNameValidator.checkAvailability(
            of: "NEW_NAME",
            takenKeys: taken,
            reservedKeys: reserved
        )
    }
}
