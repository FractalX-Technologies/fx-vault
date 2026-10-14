import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// §9.2 passphrases.
@Suite("Passphrase generator")
struct PassphraseGeneratorTests {
    static let hyphenated = ["drop-down", "felt-tip", "t-shirt", "yo-yo"]

    @Test func bundledListIsVerifiedAndFiltered() throws {
        let generator = try PassphraseGenerator.bundled()
        #expect(generator.words.count == PassphraseGenerator.expectedWordCount)
        #expect(Set(generator.words).count == generator.words.count)
        #expect(generator.words.allSatisfy { !$0.contains("-") })
        for word in Self.hyphenated {
            #expect(!generator.contains(word))
        }
        #expect(generator.words.first == "abacus")
        #expect(generator.words.last == "zoom")
        #expect(abs(generator.entropyBits - 77.5) < 0.05)
    }

    @Test func generatesSixListedWords() throws {
        let generator = try PassphraseGenerator.bundled()
        for _ in 0..<50 {
            let passphrase = try #require(generator.generate().utf8String())
            let words = passphrase.split(separator: "-").map(String.init)
            #expect(words.count == Limits.passphraseWordCount)
            #expect(words.allSatisfy(generator.contains))
        }
    }

    @Test func generationIsUniformOverTheList() throws {
        let generator = PassphraseGenerator(words: ["alpha", "bravo", "charlie", "delta"])
        var rng = SeededGenerator(seed: 7)
        var counts: [String: Int] = [:]
        for _ in 0..<2_000 {
            let text = try #require(generator.generate(using: &rng).utf8String())
            for word in text.split(separator: "-") {
                counts[String(word), default: 0] += 1
            }
        }
        // 12,000 draws over 4 words: each near 3,000.
        #expect(counts.count == 4)
        #expect(counts.values.allSatisfy { (2_700...3_300).contains($0) })
    }

    @Test func generatedPassphrasesDiffer() throws {
        let generator = try PassphraseGenerator.bundled()
        let first = try #require(generator.generate().utf8String())
        let second = try #require(generator.generate().utf8String())
        #expect(first != second)
    }

    @Test(arguments: [
        "abacus-abdomen-abdominal-abide-abiding-ability",
        "ABACUS ABDOMEN ABDOMINAL ABIDE ABIDING ABILITY",
        "  Abacus,abdomen;abdominal.abide\tabiding\nability  ",
        "abacus_abdomen 1 abdominal--abide abiding/ability",
        "abacus–abdomen—abdominal·abide abiding ability",
    ])
    func normalizesCaseWhitespaceAndSeparators(_ input: String) throws {
        let generator = try PassphraseGenerator.bundled()
        let normalized = try generator.normalize(input)
        #expect(normalized.utf8String() == "abacus-abdomen-abdominal-abide-abiding-ability")
    }

    @Test func rejectsWrongWordCount() throws {
        let generator = try PassphraseGenerator.bundled()
        #expect(throws: ShareError.invalidPassphrase(.wrongWordCount(found: 5))) {
            _ = try generator.normalize("abacus abdomen abdominal abide abiding")
        }
        #expect(throws: ShareError.invalidPassphrase(.wrongWordCount(found: 7))) {
            _ = try generator.normalize("abacus abdomen abdominal abide abiding ability able")
        }
        #expect(throws: ShareError.invalidPassphrase(.wrongWordCount(found: 0))) {
            _ = try generator.normalize("  -- 123 ")
        }
    }

    @Test func rejectsUnknownWordsByPosition() throws {
        let generator = try PassphraseGenerator.bundled()
        #expect(throws: ShareError.invalidPassphrase(.unknownWord(position: 2))) {
            _ = try generator.normalize("abacus abdomen notaword abide abiding ability")
        }
        // A hyphenated EFF word splits into parts that are not words on their own.
        #expect(throws: ShareError.invalidPassphrase(.wrongWordCount(found: 7))) {
            _ = try generator.normalize("t-shirt abdomen abdominal abide abiding ability")
        }
        // Accented letters are letters but not list words.
        #expect(throws: ShareError.invalidPassphrase(.unknownWord(position: 0))) {
            _ = try generator.normalize("abacús abdomen abdominal abide abiding ability")
        }
    }

    @Test func tamperedWordlistIsRefused() throws {
        let url = try #require(PassphraseGenerator.bundledWordlistURL)
        var data = try Data(contentsOf: url)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == PassphraseGenerator.wordlistSHA256)
        data[6] = UInt8(ascii: "b") // "abacus" -> "bbacus"
        #expect(throws: ShareError.wordlistUnavailable) { _ = try PassphraseGenerator(wordlistFile: data) }
    }
}
