import Foundation
import Testing
import VaultCore
@testable import EnvTools

@Suite("EnvImportPlanner")
struct EnvImportPlannerTests {
    private static func loadSample() throws -> DotEnvParseResult {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        var data = try Data(contentsOf: fixtures.appending(path: "sample.env"))
        return try DotEnvParser.parse(SecretBytes(wipingSource: &data))
    }

    @Test func sampleFixtureHasTwelveLines() throws {
        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let text = try String(contentsOf: fixtures.appending(path: "sample.env"), encoding: .utf8)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().count == 12)
    }

    @Test func sampleFixtureParses() throws {
        let result = try Self.loadSample()
        #expect(result.pairsWithLines == [
            ParsedPair("APP_NAME", "fx-sample-override", line: 12),
            ParsedPair("api-base-url", "https://api.example.test/v1", line: 3),
            ParsedPair("DATABASE_URL", "postgres://sample_user:not-a-password@db.example.test:5432/app", line: 4),
            ParsedPair("stripe_api_key", "sample-key-value", line: 5),
            ParsedPair("WELCOME_MESSAGE", "Hello,\nWorld", line: 6),
            ParsedPair("session.timeout", "30", line: 8),
            ParsedPair(
                "SIGNING_CERT_PEM",
                "-----BEGIN CERTIFICATE-----\nMIIBsample\n-----END CERTIFICATE-----",
                line: 9
            ),
            ParsedPair("FEATURE_FLAGS", "${OTHER_FLAGS}", line: 10),
            ParsedPair("GITHUB_TOKEN_NAME", "deploy-bot", line: 11),
        ])
        #expect(result.issues == [
            EnvParseIssue(line: 10, kind: .variableExpansionNotSupported, key: "FEATURE_FLAGS"),
            EnvParseIssue(line: 12, kind: .duplicateKey(previousLine: 2), key: "APP_NAME"),
        ])
    }

    @Test func sampleFixturePreMarksSecretsAndSuggestsKeyFixes() throws {
        let candidates = EnvImportPlanner.plan(try Self.loadSample())
        let kinds = Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            candidate.proposedName.map { ($0, candidate.suggestedKind) }
        })
        #expect(kinds == [
            "APP_NAME": .variable,
            "API_BASE_URL": .variable,
            "DATABASE_URL": .secret,
            "STRIPE_API_KEY": .secret,
            "WELCOME_MESSAGE": .variable,
            "SESSION_TIMEOUT": .variable,
            "SIGNING_CERT_PEM": .secret,
            "FEATURE_FLAGS": .variable,
            "GH_TOKEN_NAME": .secret,
        ])
        let reviewed = Set(candidates.filter(\.needsReview).map(\.key.originalKey))
        #expect(reviewed == ["api-base-url", "session.timeout", "GITHUB_TOKEN_NAME"])

        let database = try #require(candidates.first { $0.proposedName == "DATABASE_URL" })
        #expect(database.credential.reasons == [.urlWithCredentials])
        let certificate = try #require(candidates.first { $0.proposedName == "SIGNING_CERT_PEM" })
        #expect(certificate.credential.reasons == [.keyContains("CERT"), .pemBlock])
    }

    @Test func namesThatCollideAfterNormalizationGetASuffix() throws {
        let candidates = EnvImportPlanner.plan(try DotEnvParser.parse("db_url=1\nDB_URL=2\ndb-url=3"))
        #expect(candidates.map(\.proposedName) == ["DB_URL", "DB_URL_2", "DB_URL_3"])
        #expect(candidates.map(\.collidesWithLine) == [nil, 1, 1])
        #expect(candidates.map(\.needsReview) == [false, true, true])
    }

    @Test func trailingNewlinesAreStrippedWithANotice() throws {
        let candidates = EnvImportPlanner.plan(try DotEnvParser.parse(#"KEY_PEM="line1\nline2\n\r\n""#))
        let candidate = try #require(candidates.first)
        #expect(candidate.value.utf8String() == "line1\nline2")
        #expect(candidate.didStripTrailingNewlines)
        #expect(candidate.valueProblem == nil)
    }

    @Test func emptyAndOversizedValuesAreFlagged() throws {
        let oversized = String(repeating: "v", count: Limits.maxValueBytes + 1)
        let candidates = EnvImportPlanner.plan(try DotEnvParser.parse("EMPTY=\nBIG=\(oversized)\nOK=x"))
        #expect(candidates.map(\.valueProblem) == [
            .emptyValue,
            .valueTooLarge(limit: Limits.maxValueBytes),
            nil,
        ])
        #expect(candidates.map(\.needsReview) == [true, true, false])
    }

    @Test func unfixableKeysNeedAName() throws {
        let candidate = try #require(EnvImportPlanner.plan(try DotEnvParser.parse("---=1")).first)
        #expect(candidate.proposedName == nil)
        #expect(candidate.needsReview)
    }
}
