import Foundation
import Testing
import VaultCore

@Suite("PathSegmentValidator")
struct PathSegmentValidatorTests {
    @Test(arguments: [
        "production",
        "my-repo",
        "Example.Org",
        "API_KEY",
        "Producción",
        "a.b",
        "...",
        ".hidden",
        "100%",
        "%zz",
        "release-2026",
        "名前",
    ])
    func acceptsSafeSegments(segment: String) throws {
        #expect(try PathSegmentValidator.validate(segment) == segment)
        #expect(PathSegmentValidator.isValid(segment))
    }

    @Test(arguments: [
        ("", PathSegmentRule.empty),
        (".", .dotSegment),
        ("..", .dotSegment),
        ("a/b", .separator),
        ("a/..", .separator),
        ("/", .separator),
        ("a\\b", .separator),
        ("%2E", .encodedDotSegment),
        ("%2e%2E", .encodedDotSegment),
        (".%2e", .encodedDotSegment),
        ("%2E.", .encodedDotSegment),
        ("%252E%252E", .encodedDotSegment),
        ("%25252e%25252e", .encodedDotSegment),
        ("a%2Fb", .separator),
        ("%2F", .separator),
        ("a%5Cb", .separator),
        ("..%2F", .separator),
        ("a%00b", .controlCharacter),
        ("a\u{0}b", .controlCharacter),
        ("tab\tname", .controlCharacter),
        ("line\nbreak", .controlCharacter),
        ("del\u{7F}", .controlCharacter),
        ("c1\u{85}", .controlCharacter),
        ("prod\u{202E}doc", .bidiCharacter),
        ("\u{2066}x\u{2069}", .bidiCharacter),
        ("rlm\u{200F}", .bidiCharacter),
        ("zw\u{200B}sp", .zeroWidthCharacter),
        ("zwj\u{200D}", .zeroWidthCharacter),
        ("\u{FEFF}bom", .zeroWidthCharacter),
    ])
    func rejectsUnsafeSegments(segment: String, rule: PathSegmentRule) {
        #expect(PathSegmentValidator.violation(in: segment) == rule)
        #expect(!PathSegmentValidator.isValid(segment))
        #expect(throws: ValidationError.invalidPathSegment(rule)) {
            try PathSegmentValidator.validate(segment)
        }
    }

    @Test func decodingStopsAfterTheConfiguredDepth() {
        // Encode ".." one level deeper than the validator decodes: it is then an opaque string
        // that GitHubPath percent-encodes again, so it can never become a dot segment.
        var encoded = "%2E%2E"
        for _ in 0..<Limits.maxPercentDecodingPasses {
            encoded = encoded.replacingOccurrences(of: "%", with: "%25")
        }
        #expect(PathSegmentValidator.isValid(encoded))
    }
}
