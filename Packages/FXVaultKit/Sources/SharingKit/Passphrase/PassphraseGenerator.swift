import CryptoKit
import Foundation
import VaultCore

/// Six-word `.fxvault` passphrases from the EFF large wordlist (§9.2).
///
/// - The bundled `eff_large_wordlist.txt` (EFF, CC BY 3.0 US) is checked against its pinned
///   SHA-256 before use.
/// - The four hyphenated words (`drop-down felt-tip t-shirt yo-yo`) are excluded, leaving 7,772
///   words (about 77.5 bits for six words), so a passphrase splits unambiguously on `-`.
/// - Words are drawn with `SystemRandomNumberGenerator` (uniform, no modulo bias).
/// - User input is lowercased, split on every non-letter and must hold exactly six known words.
public struct PassphraseGenerator: Sendable {
    /// Separator between words in a generated or normalized passphrase.
    public static let separator = "-"
    /// SHA-256 of the bundled wordlist file.
    public static let wordlistSHA256 = "addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e"
    /// Words in the bundled list once hyphenated words are removed.
    public static let expectedWordCount = 7_772

    private static let resourceName = "eff_large_wordlist"
    private static let resourceExtension = "txt"
    private static let fieldSeparator: Character = "\t"

    /// The usable words, in list order.
    public let words: [String]
    private let wordSet: Set<String>

    /// Creates a generator over `words` (tests; production uses ``bundled()``).
    init(words: [String]) {
        self.words = words
        wordSet = Set(words)
    }

    /// Loads, verifies and filters the bundled wordlist.
    public static func bundled() throws(ShareError) -> PassphraseGenerator {
        guard let url = bundledWordlistURL, let data = try? Data(contentsOf: url) else {
            throw .wordlistUnavailable
        }
        return try PassphraseGenerator(wordlistFile: data)
    }

    /// The bundled `eff_large_wordlist.txt`.
    static var bundledWordlistURL: URL? {
        Bundle.module.url(forResource: resourceName, withExtension: resourceExtension)
    }

    /// Parses an EFF-format file (`NNNNN<TAB>word` per line) after checking its SHA-256.
    init(wordlistFile data: Data) throws(ShareError) {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.wordlistSHA256, let text = String(data: data, encoding: .utf8) else {
            throw .wordlistUnavailable
        }
        let parsed = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard let word = line.split(separator: Self.fieldSeparator).last else { return nil }
            let candidate = String(word)
            return candidate.allSatisfy(Self.isWordLetter) ? candidate : nil
        }
        guard parsed.count == Self.expectedWordCount else { throw .wordlistUnavailable }
        self.init(words: parsed)
    }

    /// Bits of entropy in one generated passphrase.
    public var entropyBits: Double {
        Double(Limits.passphraseWordCount) * log2(Double(words.count))
    }

    /// A new passphrase, `w1-w2-w3-w4-w5-w6`.
    public func generate() -> SecretBytes {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    /// A new passphrase drawn with `generator`.
    public func generate(using generator: inout some RandomNumberGenerator) -> SecretBytes {
        var chosen: [String] = []
        for _ in 0..<Limits.passphraseWordCount {
            chosen.append(words[Int.random(in: words.indices, using: &generator)])
        }
        return SecretBytes(utf8: chosen.joined(separator: Self.separator))
    }

    /// Normalizes typed input to `w1-…-w6` for the KDF: lowercased, split on non-letters,
    /// exactly six words, each in the list.
    public func normalize(_ input: String) throws(ShareError) -> SecretBytes {
        let tokens = input.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        guard tokens.count == Limits.passphraseWordCount else {
            throw .invalidPassphrase(.wrongWordCount(found: tokens.count))
        }
        if let position = tokens.firstIndex(where: { !wordSet.contains($0) }) {
            throw .invalidPassphrase(.unknownWord(position: position))
        }
        return SecretBytes(utf8: tokens.joined(separator: Self.separator))
    }

    /// Whether `word` is in the usable list.
    public func contains(_ word: String) -> Bool {
        wordSet.contains(word)
    }

    private static func isWordLetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter && character.isLowercase
    }
}
