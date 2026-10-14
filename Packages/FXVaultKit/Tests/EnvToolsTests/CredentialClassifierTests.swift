import Foundation
import Testing
import VaultCore
@testable import EnvTools

/// Token-shaped test values are assembled at run time from pieces so secret scanners never see
/// a realistic token literal in this file. None of them is a real credential.
private enum Samples {
    static let gitHubClassic = "ghp_" + TestValues.randomToken(length: 36, seed: 1)
    static let gitHubOAuth = "gho_" + TestValues.randomToken(length: 36, seed: 2)
    static let gitHubFineGrained = "github" + "_pat_" + TestValues.randomToken(length: 40, seed: 3)
    static let stripeLive = "sk_" + "live_" + TestValues.randomToken(length: 24, seed: 4)
    static let awsAccessKey = "AK" + "IA" + TestValues.randomToken(
        length: 16, alphabet: TestValues.upperAlphanumerics, seed: 5
    )
    static let slackBot = "xox" + "b-" + "1234567890-" + TestValues.randomToken(length: 12, seed: 6)
    static let slackUser = "xox" + "p-" + "1234567890-" + TestValues.randomToken(length: 12, seed: 7)
    static let jwt = [
        "eyJhbGciOiJIUzI1NiJ9",
        "eyJzdWIiOiJzYW1wbGUifQ",
        TestValues.randomToken(length: 43, seed: 8),
    ].joined(separator: ".")
    static let unsignedJWT = ["eyJhbGciOiJub25lIn0", "eyJzdWIiOiJ4In0", ""].joined(separator: ".")
    static let pemPrivate = "-----BEGIN " + "RSA PRIV" + "ATE KEY-----\nMIIBsample\n-----END RSA PRIV" + "ATE KEY-----"
    static let pemCertificate = "-----BEGIN CERTIFICATE-----\nMIIBsample\n-----END CERTIFICATE-----"
    static let randomMixed = TestValues.randomToken(length: 32, seed: 9)
    static let hexDigest = TestValues.randomToken(length: 64, alphabet: Array("0123456789abcdef"), seed: 10)
}

@Suite("CredentialClassifier")
struct CredentialClassifierTests {
    // MARK: - Keys

    @Test(
        "key patterns",
        arguments: [
            ("GITHUB_TOKEN", "TOKEN"),
            ("api_key", "KEY"),
            ("DB_PASSWORD", "PASSWORD"),
            ("CLIENT_SECRET", "SECRET"),
            ("PRIVATE_NOTE", "PRIVATE"),
            ("SMTP_PASS", "PASS"),
            ("MYSQL_PWD", "PWD"),
            ("GOOGLE_CREDENTIALS", "CREDENTIAL"),
            ("AUTH0_DOMAIN", "AUTH"),
            ("SENTRY_DSN", "DSN"),
            ("TLS_CERT", "CERT"),
            ("APNS_PEM", "PEM"),
            ("SIGNING_IDENTITY", "SIGNING"),
            ("SLACK_WEBHOOK_URL", "WEBHOOK"),
            ("apiKey", "KEY"),
        ]
    )
    func keyPattern(key: String, pattern: String) {
        #expect(CredentialClassifier.keyReasons(for: key) == [.keyContains(pattern)])
        #expect(CredentialClassifier.assess(key: key, value: nil).isLikelyCredential)
    }

    @Test("neutral keys", arguments: ["APP_NAME", "LOG_LEVEL", "PORT", "DATABASE_HOST", "FEATURE_FLAGS"])
    func neutralKey(key: String) {
        #expect(CredentialClassifier.keyReasons(for: key).isEmpty)
        #expect(CredentialClassifier.assess(key: key, value: nil) == .none)
    }

    @Test func everySpecPatternIsListed() {
        let spec = ["TOKEN", "KEY", "PASSWORD", "SECRET", "PRIVATE", "PASS", "PWD", "CREDENTIAL",
                    "AUTH", "DSN", "CERT", "PEM", "SIGNING", "WEBHOOK"]
        #expect(Set(CredentialClassifier.keyPatterns) == Set(spec))
    }

    // MARK: - Values

    @Test(
        "value heuristics",
        arguments: [
            ("postgres://user:pw@db.example.test:5432/app", CredentialReason.urlWithCredentials),
            ("redis://:pw@cache.example.test:6379", .urlWithCredentials),
            ("amqp://guest:guest@localhost", .urlWithCredentials),
            (Samples.pemPrivate, .pemBlock),
            (Samples.pemCertificate, .pemBlock),
            (Samples.jwt, .jsonWebToken),
            ("Bearer " + Samples.jwt, .jsonWebToken),
            (Samples.unsignedJWT, .jsonWebToken),
            (Samples.gitHubClassic, .knownTokenPrefix("ghp_")),
            (Samples.gitHubOAuth, .knownTokenPrefix("gho_")),
            (Samples.gitHubFineGrained, .knownTokenPrefix("github_pat_")),
            (Samples.stripeLive, .knownTokenPrefix("sk_live_")),
            (Samples.awsAccessKey, .knownTokenPrefix("AKIA")),
            (Samples.slackBot, .knownTokenPrefix("xoxb-")),
            (Samples.slackUser, .knownTokenPrefix("xoxp-")),
            ("token=" + Samples.gitHubClassic, .knownTokenPrefix("ghp_")),
            (Samples.randomMixed, .highEntropy),
            (Samples.hexDigest, .highEntropy),
        ]
    )
    func valueHeuristic(value: String, reason: CredentialReason) {
        let reasons = CredentialClassifier.valueReasons(in: SecretBytes(utf8: value))
        #expect(reasons.contains(reason), "\(reasons)")
        #expect(CredentialClassifier.valueReasons(in: value) == reasons)
        #expect(CredentialClassifier.assess(key: "VALUE", value: SecretBytes(utf8: value)).isLikelyCredential)
    }

    @Test(
        "values that are not credentials",
        arguments: [
            "",
            "production",
            "30",
            "true",
            "https://user@host.example.test",
            "https://api.example.test:8443/v1/resources/items",
            "see https://a.example.test and mail me: x@y.test",
            "production-database-cluster",
            "this is a long sentence with many ordinary words",
            "/usr/local/share/applications/sample",
            "aaaaaaaaaaaaaaaaaaaaaaaa1",
            "aB3dE5",
            "ghp_short",
            "-----BEGIN -----",
        ]
    )
    func notACredential(value: String) {
        #expect(CredentialClassifier.valueReasons(in: SecretBytes(utf8: value)).isEmpty)
        #expect(CredentialClassifier.assess(key: "VALUE", value: value) == .none)
    }

    @Test func tokenPrefixNeedsABoundaryAndATail() {
        let glued = "MY" + Samples.awsAccessKey
        let testKey = "sk_" + "test_" + TestValues.randomToken(length: 24, seed: 11)
        #expect(!CredentialClassifier.valueReasons(in: glued).contains { reason in
            if case .knownTokenPrefix = reason { return true }
            return false
        })
        #expect(!CredentialClassifier.valueReasons(in: testKey).contains { reason in
            if case .knownTokenPrefix = reason { return true }
            return false
        })
    }

    @Test func keyAndValueReasonsAreCombinedKeyFirst() {
        let assessment = CredentialClassifier.assess(
            key: "DATABASE_PASSWORD_URL",
            value: SecretBytes(utf8: "postgres://u:p@h/db")
        )
        #expect(assessment.reasons == [.keyContains("PASSWORD"), .urlWithCredentials])
        #expect(assessment.suggestedKind == .secret)
        #expect(CredentialAssessmentModel.none.suggestedKind == .variable)
    }

    @Test func classifyingDoesNotModifyTheValue() {
        let value = SecretBytes(utf8: Samples.gitHubClassic)
        _ = CredentialClassifier.assess(key: "X", value: value)
        #expect(value.utf8String() == Samples.gitHubClassic)
    }

    // MARK: - Entropy

    @Test func shannonEntropyValues() {
        func entropy(_ bytes: [UInt8]) -> Double {
            bytes.withUnsafeBytes { CredentialClassifier.shannonEntropy(of: $0) }
        }
        let tolerance = 1e-9
        #expect(entropy([]) == 0)
        #expect(entropy(Array("aaaa".utf8)) == 0)
        #expect(abs(entropy(Array("ab".utf8)) - 1) < tolerance)
        #expect(abs(entropy(Array("abcd".utf8)) - 2) < tolerance)
        #expect(abs(entropy((0...255).map { UInt8($0) }) - 8) < tolerance)
    }
}
