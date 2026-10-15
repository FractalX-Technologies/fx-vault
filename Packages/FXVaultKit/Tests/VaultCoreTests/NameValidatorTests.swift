import Testing
import VaultCore

@Suite("RepoNameValidator")
struct RepoNameValidatorTests {
    @Test(arguments: ["api", "fx-vault", "my_repo.web", "A1", "...", ".github", "x.gitx", "repo.git2"])
    func acceptsNames(name: String) throws {
        #expect(try RepoNameValidator.validate(name) == name)
    }

    @Test(arguments: [
        ("", NameRule.empty),
        (".", .dotName),
        ("..", .dotName),
        ("repo.git", .gitSuffix),
        ("repo.GIT", .gitSuffix),
        (".git", .gitSuffix),
        ("my repo", .invalidCharacter),
        ("my/repo", .invalidCharacter),
        ("répo", .invalidCharacter),
        ("repo%2E", .invalidCharacter),
        ("repo\t", .controlCharacter),
        ("repo\u{202E}", .bidiCharacter),
        ("re\u{200B}po", .zeroWidthCharacter),
        (String(repeating: "r", count: Limits.maxRepoNameLength + 1),
         .tooLong(maxLength: Limits.maxRepoNameLength)),
    ])
    func rejectsNames(name: String, rule: NameRule) {
        #expect(RepoNameValidator.violation(in: name) == rule)
        #expect(throws: ValidationError.invalidName(rule)) {
            try RepoNameValidator.validate(name)
        }
    }

    @Test func acceptsTheMaximumLength() {
        #expect(RepoNameValidator.isValid(String(repeating: "r", count: Limits.maxRepoNameLength)))
    }

    @Test(arguments: [
        ("My App", "My-App"),
        ("café api", "cafe-api"),
        ("tool.git", "tool"),
        ("  spaced  ", "spaced"),
    ])
    func suggestsAFix(name: String, expected: String) {
        #expect(RepoNameValidator.suggestedFix(for: name) == expected)
    }

    @Test(arguments: ["valid-name", "..", "日本", ""])
    func noFixWhenValidOrUnusable(name: String) {
        #expect(RepoNameValidator.suggestedFix(for: name) == nil)
    }

    @Test func validNamesAreSafePathSegments() {
        for name in ["api", "...", ".github", "a_b-c.d"] {
            #expect(RepoNameValidator.isValid(name))
            #expect(PathSegmentValidator.isValid(name))
        }
    }
}

@Suite("OwnerLoginValidator")
struct OwnerLoginValidatorTests {
    @Test(arguments: ["octocat", "Example-Org", "a", "a1-b2", "legacy--name", "trailing-"])
    func acceptsLogins(login: String) throws {
        #expect(try OwnerLoginValidator.validate(login) == login)
    }

    /// Enterprise Managed User logins: `<normalized handle>_<short code>` (synthetic examples in
    /// the documented shapes, including digit-only handles and the `-e` style handle suffix),
    /// and the setup user `<short code>_admin`.
    @Test(arguments: [
        "octocat_octo", "mona-cat_acme", "name-e_shortcode", "user1_acme", "user1-e_acme",
        "1234567_acme", "1234567-e_acme", "acme_admin", "USER1_ACME",
    ])
    func acceptsEnterpriseManagedUserLogins(login: String) throws {
        #expect(try OwnerLoginValidator.validate(login) == login)
        #expect(PathSegmentValidator.isValid(login), "valid logins stay safe path segments")
    }

    @Test func managedUserLoginsShareTheThirtyNineCharacterLimit() {
        let shortCode = "_acme"
        let longest = String(repeating: "a", count: Limits.maxOwnerLoginLength - shortCode.count) + shortCode
        #expect(longest.count == Limits.maxOwnerLoginLength)
        #expect(OwnerLoginValidator.isValid(longest))
        #expect(OwnerLoginValidator.violation(in: "a" + longest) == .tooLong(maxLength: Limits.maxOwnerLoginLength))
    }

    @Test func foldKeysOfManagedUserLoginsAreCaseInsensitive() {
        #expect(OwnerLoginValidator.foldKey("User1-E_Acme") == OwnerLoginValidator.foldKey("user1-e_ACME"))
        #expect(OwnerLoginValidator.foldKey("User1_Acme") != OwnerLoginValidator.foldKey("user1-acme"))
    }

    @Test(arguments: [
        ("", NameRule.empty),
        ("-octocat", .invalidFirstCharacter),
        ("_octocat", .invalidFirstCharacter),
        ("_", .invalidFirstCharacter),
        ("octo/cat_acme", .invalidCharacter),
        ("octo.cat", .invalidCharacter),
        ("octo cat", .invalidCharacter),
        ("ñandú", .invalidCharacter),
        ("octo\n", .controlCharacter),
        (String(repeating: "a", count: Limits.maxOwnerLoginLength + 1),
         .tooLong(maxLength: Limits.maxOwnerLoginLength)),
    ])
    func rejectsLogins(login: String, rule: NameRule) {
        #expect(OwnerLoginValidator.violation(in: login) == rule)
    }

    @Test func acceptsTheMaximumLength() {
        #expect(OwnerLoginValidator.isValid(String(repeating: "a", count: Limits.maxOwnerLoginLength)))
    }

    @Test func foldKeyIsLowercase() {
        #expect(OwnerLoginValidator.foldKey("Admin-Example") == "admin-example")
    }
}

@Suite("GitHubHostValidator and BranchPatternValidator")
struct HostAndPatternValidatorTests {
    @Test func onlyGitHubDotComIsAccepted() throws {
        #expect(try GitHubHostValidator.validate("github.com") == "github.com")
        for host in ["GitHub.com", "github.com.", "api.github.com", "github.com:443", "ghe.example.com", ""] {
            #expect(throws: ValidationError.invalidHost) {
                try GitHubHostValidator.validate(host)
            }
        }
    }

    @Test(arguments: ["main", "release/*", "v*.*.*", "feature/**/x", "*"])
    func acceptsPatterns(pattern: String) throws {
        #expect(try BranchPatternValidator.validate(pattern) == pattern)
    }

    @Test(arguments: [
        ("", NameRule.empty),
        ("release/\u{202E}*", .bidiCharacter),
        ("main\n", .controlCharacter),
        ("ma\u{200D}in", .zeroWidthCharacter),
        (String(repeating: "p", count: Limits.maxBranchPatternLength + 1),
         .tooLong(maxLength: Limits.maxBranchPatternLength)),
    ])
    func rejectsPatterns(pattern: String, rule: NameRule) {
        #expect(BranchPatternValidator.violation(in: pattern) == rule)
    }
}

@Suite("DisplayNameSanitizer")
struct DisplayNameSanitizerTests {
    @Test(arguments: [
        ("Alex", "Alex"),
        ("  Alex  ", "Alex"),
        ("Al\u{202E}ex", "Alex"),
        ("Al\u{200B}ex\n", "Alex"),
        ("Al\u{0}ex", "Alex"),
        ("Jose\u{301}", "Jos\u{E9}"),
        ("\u{2066}\u{2069}", ""),
        // Invisible characters a peer could hide in a name.
        ("Al\u{E0041}\u{E0042}ex", "Alex"),
        ("Al\u{00AD}ex\u{2062}", "Alex"),
        ("\u{3164}Alex\u{115F}", "Alex"),
        ("Al\u{FFF9}ex\u{FFFB}", "Alex"),
    ])
    func sanitizes(input: String, expected: String) {
        let output = DisplayNameSanitizer.sanitize(input)
        #expect(Array(output.unicodeScalars) == Array(expected.unicodeScalars))
    }

    @Test func truncatesOnACharacterBoundary() {
        // "é" is 2 UTF-8 bytes; 40 of them (80 bytes) must cut to 31 (62 bytes ≤ 63).
        let output = DisplayNameSanitizer.sanitize(String(repeating: "é", count: 40))
        #expect(output.utf8.count <= Limits.maxDisplayNameBytes)
        #expect(output == String(repeating: "é", count: 31))
    }

    @Test func neverSplitsAGrapheme() {
        let family = "👨‍👩‍👧"  // contains zero-width joiners, which are removed first
        let output = DisplayNameSanitizer.sanitize(String(repeating: family, count: 20))
        #expect(output.utf8.count <= Limits.maxDisplayNameBytes)
        #expect(UnicodeScalarPolicy.firstViolation(in: output) == nil)
        let flag = "🇦🇪"
        let flags = DisplayNameSanitizer.sanitize(String(repeating: flag, count: 20), maxBytes: 10)
        #expect(flags == flag)
    }
}

@Suite("ScopeCapacityValidator")
struct ScopeCapacityValidatorTests {
    @Test(arguments: [
        (ConfigKind.secret, ConfigScopeLevel.repository, 100),
        (.secret, .environment, 100),
        (.variable, .repository, 500),
        (.variable, .environment, 100),
    ])
    func limitsMatchGitHub(kind: ConfigKind, level: ConfigScopeLevel, limit: Int) throws {
        #expect(Limits.maxItems(kind: kind, level: level) == limit)
        try ScopeCapacityValidator.validate(currentCount: limit - 1, kind: kind, level: level)
        #expect(throws: ValidationError.scopeFull(kind: kind, limit: limit)) {
            try ScopeCapacityValidator.validate(currentCount: limit, kind: kind, level: level)
        }
        #expect(throws: ValidationError.scopeFull(kind: kind, limit: limit)) {
            try ScopeCapacityValidator.validate(currentCount: 0, adding: limit + 1, kind: kind, level: level)
        }
        #expect(ScopeCapacityValidator.remainingCapacity(currentCount: limit + 5, kind: kind, level: level) == 0)
    }
}
