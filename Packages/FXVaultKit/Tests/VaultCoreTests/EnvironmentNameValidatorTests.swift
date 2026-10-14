import Foundation
import Testing
import VaultCore

@Suite("EnvironmentNameValidator")
struct EnvironmentNameValidatorTests {
    /// "Producción" with a precomposed ó (U+00F3).
    static let composed = "Producci\u{F3}n"
    /// "Producción" with o + combining acute accent (U+0301).
    static let decomposed = "Produccio\u{301}n"
    /// "PRODUCCIÓN" with a precomposed Ó (U+00D3).
    static let upperComposed = "PRODUCCI\u{D3}N"
    /// "PRODUCCIÓN" with O + combining acute accent.
    static let upperDecomposed = "PRODUCCIO\u{301}N"

    @Test(arguments: [
        "production",
        "staging",
        "QA env",
        "prod-eu.1",
        "Producción",
        "本番",
        "release (v2)",
        "a",
    ])
    func acceptsNames(name: String) throws {
        #expect(try EnvironmentNameValidator.validate(name) == name)
    }

    @Test(arguments: [
        ("", ValidationError.invalidName(.empty)),
        (" production", .invalidName(.leadingOrTrailingWhitespace)),
        ("production ", .invalidName(.leadingOrTrailingWhitespace)),
        ("\u{A0}prod", .invalidName(.leadingOrTrailingWhitespace)),
        ("prod\u{3000}", .invalidName(.leadingOrTrailingWhitespace)),
        ("prod\nuction", .invalidName(.controlCharacter)),
        ("prod\u{0}", .invalidName(.controlCharacter)),
        ("prod\u{9F}", .invalidName(.controlCharacter)),
        ("prod\u{2028}x", .invalidName(.controlCharacter)),
        ("prod\u{202E}noitcudorp", .invalidName(.bidiCharacter)),
        ("prod\u{200E}", .invalidName(.bidiCharacter)),
        ("\u{2067}prod", .invalidName(.bidiCharacter)),
        ("pro\u{200B}d", .invalidName(.zeroWidthCharacter)),
        ("pro\u{200C}d", .invalidName(.zeroWidthCharacter)),
        ("prod\u{FEFF}", .invalidName(.zeroWidthCharacter)),
        (".", .invalidPathSegment(.dotSegment)),
        ("..", .invalidPathSegment(.dotSegment)),
        ("prod/eu", .invalidPathSegment(.separator)),
        ("%2E%2E", .invalidPathSegment(.encodedDotSegment)),
        ("a%2F..", .invalidPathSegment(.separator)),
    ])
    func rejectsNames(name: String, error: ValidationError) {
        #expect(EnvironmentNameValidator.violation(in: name) == error)
        #expect(throws: error) {
            try EnvironmentNameValidator.validate(name)
        }
    }

    @Test func lengthCountsUnicodeScalars() {
        let maxASCII = String(repeating: "a", count: Limits.maxEnvironmentNameLength)
        let maxNonASCII = String(repeating: "é", count: Limits.maxEnvironmentNameLength)
        let tooLong = String(repeating: "é", count: Limits.maxEnvironmentNameLength + 1)
        #expect(EnvironmentNameValidator.isValid(maxASCII))
        #expect(EnvironmentNameValidator.isValid(maxNonASCII))
        #expect(
            EnvironmentNameValidator.violation(in: tooLong)
                == .invalidName(.tooLong(maxLength: Limits.maxEnvironmentNameLength))
        )
    }

    @Test func decomposedLengthIsMeasuredAfterNFC() {
        // 255 decomposed "é" are 510 scalars but 255 after NFC.
        let decomposed = String(repeating: "e\u{301}", count: Limits.maxEnvironmentNameLength)
        #expect(EnvironmentNameValidator.isValid(decomposed))
    }

    @Test func validateReturnsNFC() throws {
        let stored = try EnvironmentNameValidator.validate(Self.decomposed)
        #expect(Array(stored.unicodeScalars) == Array(Self.composed.unicodeScalars))
    }

    @Test func strictModeRejectsNonNFC() throws {
        #expect(throws: ValidationError.invalidName(.notNormalized)) {
            try EnvironmentNameValidator.validate(Self.decomposed, requireNFC: true)
        }
        #expect(try EnvironmentNameValidator.validate(Self.composed, requireNFC: true) == Self.composed)
    }

    @Test(arguments: [
        (composed, upperComposed),
        (composed, upperDecomposed),
        (decomposed, upperComposed),
        (decomposed, upperDecomposed),
        ("Staging", "STAGING"),
        ("QA Env", "qa env"),
    ])
    func foldKeysMatchAcrossCaseAndNormalization(lhs: String, rhs: String) {
        #expect(EnvironmentNameValidator.foldKey(lhs) == EnvironmentNameValidator.foldKey(rhs))
    }

    @Test func foldKeyIsNFCLowercase() {
        let key = EnvironmentNameValidator.foldKey(Self.upperDecomposed)
        #expect(Array(key.unicodeScalars) == Array("producci\u{F3}n".unicodeScalars))
    }

    @Test(arguments: [("production", "prod"), ("staging", "stage"), ("Producción", "Produccion")])
    func foldKeysDifferForDifferentNames(lhs: String, rhs: String) {
        #expect(EnvironmentNameValidator.foldKey(lhs) != EnvironmentNameValidator.foldKey(rhs))
    }

    @Test func availabilityUsesFoldKeys() throws {
        let taken: Set = [EnvironmentNameValidator.foldKey(Self.composed)]
        let reserved: Set = [EnvironmentNameValidator.foldKey("staging")]
        #expect(throws: ValidationError.duplicateName) {
            try EnvironmentNameValidator.checkAvailability(of: Self.upperDecomposed, takenKeys: taken)
        }
        #expect(throws: ValidationError.nameReservedByPendingChange) {
            try EnvironmentNameValidator.checkAvailability(
                of: "STAGING",
                takenKeys: taken,
                reservedKeys: reserved
            )
        }
        try EnvironmentNameValidator.checkAvailability(
            of: "qa",
            takenKeys: taken,
            reservedKeys: reserved
        )
    }
}
