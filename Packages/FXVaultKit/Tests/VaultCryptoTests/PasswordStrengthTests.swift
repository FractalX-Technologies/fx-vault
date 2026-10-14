import Foundation
import Testing
import VaultCore
@testable import VaultCrypto

@Suite("PasswordStrength")
struct PasswordStrengthTests {
    @Test func rejectsPassword1234() {
        let result = PasswordStrength.evaluate("password1234")
        #expect(result.characterCount == 12)
        #expect(!result.isAcceptable)
        #expect(result.estimatedBits < Double(Limits.minPasswordStrengthBits))
        #expect(result.weaknesses.contains(.commonWord))
        #expect(result.weaknesses.contains(.sequence))
        #expect(result.weaknesses.contains(.lowEstimatedStrength))
        #expect(!result.weaknesses.contains(.tooShort))
    }

    @Test(arguments: [
        "Password1234",
        "P@ssw0rd2024!",
        "qwertyuiop12",
        "aaaaaaaaaaaaaaaa",
        "abcabcabcabcabc",
        "123456789012",
        "iloveyou2025",
        "Dragon1990Dragon",
        "letmein-letmein",
        "1q2w3e4r5t6y",
        "zyxwvutsrqpo",
        "FXVault2026!!",
    ])
    func rejectsPredictablePasswords(password: String) {
        let result = PasswordStrength.evaluate(password)
        #expect(!result.isAcceptable, "\(password): \(result.estimatedBits) bits")
        #expect(result.weaknesses.contains(.lowEstimatedStrength))
    }

    @Test func reportsPatterns() {
        #expect(PasswordStrength.evaluate("qwertyqwertyzz").weaknesses.contains(.keyboardPattern) ||
            PasswordStrength.evaluate("qwertyqwertyzz").weaknesses.contains(.commonWord))
        #expect(PasswordStrength.evaluate("zzzzzzzzzzzzzzzzzzzz").weaknesses.contains(.repetition))
        #expect(PasswordStrength.evaluate("Xk9#mQ2$1987").weaknesses.contains(.year))
        #expect(PasswordStrength.evaluate("asdfghjkl;'\\").weaknesses.contains(.keyboardPattern))
    }

    @Test func rejectsShortPasswordsEvenWhenRandom() {
        let result = PasswordStrength.evaluate("Xk9#mQ2$vL")
        #expect(result.characterCount == 10)
        #expect(result.weaknesses.first == .tooShort)
        #expect(!result.isAcceptable)
    }

    @Test func emptyPassword() {
        let result = PasswordStrength.evaluate("")
        #expect(result.estimatedBits == 0)
        #expect(result.weaknesses == [.tooShort, .lowEstimatedStrength])
    }

    @Test func acceptsGeneratedSixWordPassphrases() throws {
        let words = try effWords()
        #expect(words.count == 7_772)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<100 {
            let passphrase = (0..<Limits.passphraseWordCount)
                .compactMap { _ in words.randomElement(using: &generator) }
                .joined(separator: "-")
            let result = PasswordStrength.evaluate(passphrase)
            #expect(result.isAcceptable, "\(passphrase): \(result.estimatedBits) bits")
        }
    }

    /// The weakest realistic generated passphrase: six distinct list words that are also in the
    /// estimator's common-word table, shortest first.
    @Test func acceptsWorstCaseGeneratedPassphrase() throws {
        let words = Set(try effWords())
        let common = PasswordStrengthTables.commonWords
            .map { String($0) }
            .filter { words.contains($0) }
            .sorted { ($0.count, $0) < ($1.count, $1) }
        #expect(common.count >= Limits.passphraseWordCount)
        let passphrase = common.prefix(Limits.passphraseWordCount).joined(separator: "-")
        let result = PasswordStrength.evaluate(passphrase)
        #expect(result.isAcceptable, "\(passphrase): \(result.estimatedBits) bits")
    }

    @Test(arguments: ["Xk9#mQ2$vLp7&Rw", "tR8!zQ4@bN6#yH2*", "مرحبا-كلمة-سرية-قوية-2"])
    func acceptsStrongPasswords(password: String) {
        #expect(PasswordStrength.evaluate(password).isAcceptable)
    }

    @Test func countsCharactersAfterNFC() {
        let decomposed = String(repeating: "e\u{0301}", count: 12)
        #expect(PasswordStrength.evaluate(decomposed).characterCount == 12)
    }

    @Test func boundsWorkOnHugeInput() {
        let huge = String(repeating: "Xk9#mQ2$vL", count: 10_000)
        let clock = ContinuousClock()
        let start = clock.now
        let result = PasswordStrength.evaluate(huge)
        #expect(result.characterCount == 100_000)
        #expect(result.isAcceptable)
        #expect(clock.now - start < .seconds(5))
    }

    private func effWords() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SharingKit/Resources/eff_large_wordlist.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        // §9.2: the four hyphenated words are excluded.
        return text.split(separator: "\n").compactMap { line in
            line.split(separator: "\t").last.map(String.init)
        }
        .filter { !$0.contains("-") }
    }
}
