import Foundation
import VaultCore

/// A pattern that made a password weaker than its length suggests. The app maps each case to a
/// localized hint.
public enum PasswordWeakness: String, Sendable, Hashable, CaseIterable {
    /// Fewer than ``Limits/minPasswordLength`` characters.
    case tooShort
    /// Estimated strength below ``Limits/minPasswordStrengthBits`` bits.
    case lowEstimatedStrength
    /// Contains a common password word (also with simple substitutions such as `p@ssw0rd`).
    case commonWord
    /// Contains a run such as `1234`, `abcd` or `9876`.
    case sequence
    /// Contains a keyboard row run such as `qwerty` or `asdf`.
    case keyboardPattern
    /// Repeats a character or a block (`aaaa`, `abcabc`).
    case repetition
    /// Contains a year (`1900`-`2099`).
    case year
}

/// The result of ``PasswordStrength/evaluate(_:)``.
public struct PasswordStrengthModel: Sendable, Hashable {
    /// Characters (grapheme clusters) after NFC normalization.
    public let characterCount: Int
    /// Conservative estimate of the guessing entropy, in bits.
    public let estimatedBits: Double
    /// Patterns found on the cheapest way to guess the password, in a stable order.
    public let weaknesses: [PasswordWeakness]

    public init(characterCount: Int, estimatedBits: Double, weaknesses: [PasswordWeakness]) {
        self.characterCount = characterCount
        self.estimatedBits = estimatedBits
        self.weaknesses = weaknesses
    }

    /// D8: at least ``Limits/minPasswordLength`` characters **and** at least
    /// ``Limits/minPasswordStrengthBits`` estimated bits.
    public var isAcceptable: Bool {
        characterCount >= Limits.minPasswordLength && estimatedBits >= Double(Limits.minPasswordStrengthBits)
    }
}

/// A local, offline password-strength estimator for the master password (D8).
///
/// In the spirit of zxcvbn, but small: the password is split into the cheapest sequence of
/// guessable pieces (common words with substitutions, sequences, keyboard runs, repeats, years,
/// and otherwise single characters drawn from the character classes present), and the bits of
/// those pieces are added up. It is deliberately conservative: a generated 6-word passphrase
/// passes easily, `password1234` does not. Nothing leaves the process.
public enum PasswordStrength {
    /// Evaluates `password` (NFC-normalized first, like the KDF input).
    public static func evaluate(_ password: String) -> PasswordStrengthModel {
        let characters = Array(password.precomposedStringWithCanonicalMapping)
        guard !characters.isEmpty else {
            return PasswordStrengthModel(characterCount: 0, estimatedBits: 0, weaknesses: [.tooShort, .lowEstimatedStrength])
        }
        // Patterns are searched in a bounded prefix so a pasted megabyte cannot stall the UI; the
        // rest counts as independent characters.
        let analysis = Analysis(characters: Array(characters.prefix(PasswordStrengthTables.maxAnalyzedCharacters)))
        let (coverBits, patterns) = analysis.cheapestCover()
        let remainder = characters.count - analysis.characters.count
        let bits = coverBits + Double(remainder) * analysis.characterBits
        var weaknesses: [PasswordWeakness] = []
        if characters.count < Limits.minPasswordLength {
            weaknesses.append(.tooShort)
        }
        if bits < Double(Limits.minPasswordStrengthBits) {
            weaknesses.append(.lowEstimatedStrength)
        }
        weaknesses += PasswordWeakness.allCases.filter { patterns.contains($0) }
        return PasswordStrengthModel(characterCount: characters.count, estimatedBits: bits, weaknesses: weaknesses)
    }
}

// MARK: - Analysis

private struct Match {
    let start: Int
    let end: Int
    let bits: Double
    let pattern: PasswordWeakness
}

private struct Analysis {
    let characters: [Character]
    /// Lowercased form of each character (first scalar only when it changes length).
    let lowered: [Character]
    /// Bits of one character guessed from the classes present.
    let characterBits: Double

    init(characters: [Character]) {
        self.characters = characters
        lowered = characters.map { character in
            let lower = character.lowercased()
            return lower.count == 1 ? Character(lower) : character
        }
        characterBits = log2(Double(Self.poolSize(of: characters)))
    }

    /// Minimum total bits over every way of covering the password with matches and single
    /// characters, and the patterns used on that cheapest cover.
    func cheapestCover() -> (Double, Set<PasswordWeakness>) {
        let count = characters.count
        var matchesEndingAt = [[Match]](repeating: [], count: count + 1)
        for match in allMatches() {
            matchesEndingAt[match.end].append(match)
        }
        var best = [Double](repeating: .infinity, count: count + 1)
        var choice = [Match?](repeating: nil, count: count + 1)
        best[0] = 0
        for end in 1...count {
            best[end] = best[end - 1] + characterBits
            for match in matchesEndingAt[end] where best[match.start] + match.bits < best[end] {
                best[end] = best[match.start] + match.bits
                choice[end] = match
            }
        }
        var patterns = Set<PasswordWeakness>()
        var position = count
        while position > 0 {
            if let match = choice[position] {
                patterns.insert(match.pattern)
                position = match.start
            } else {
                position -= 1
            }
        }
        return (best[count], patterns)
    }

    private func allMatches() -> [Match] {
        dictionaryMatches() + sequenceMatches() + keyboardMatches() + repeatMatches() + yearMatches()
    }

    // MARK: Dictionary words (with case and substitutions)

    private func dictionaryMatches() -> [Match] {
        var matches: [Match] = []
        let wordBits = log2(Double(PasswordStrengthTables.commonWords.count))
        for start in characters.indices {
            let first = lowered[start]
            let letters = PasswordStrengthTables.substitutions[first, default: []].union([first])
            let candidates = letters.flatMap { PasswordStrengthTables.commonWordsByFirstLetter[$0, default: []] }
            for word in candidates where start + word.count <= characters.count {
                var substitutions = 0
                var isMatch = true
                for (offset, letter) in word.enumerated() {
                    let candidate = lowered[start + offset]
                    if candidate == letter { continue }
                    if PasswordStrengthTables.substitutions[candidate]?.contains(letter) == true {
                        substitutions += 1
                    } else {
                        isMatch = false
                        break
                    }
                }
                guard isMatch else { continue }
                let end = start + word.count
                let bits = wordBits + uppercaseBits(start..<end) + Double(substitutions)
                matches.append(Match(start: start, end: end, bits: bits, pattern: .commonWord))
            }
        }
        return matches
    }

    /// 0 bits for all lowercase, 1 bit for a capitalized or all-uppercase word, otherwise one bit
    /// per uppercase letter.
    private func uppercaseBits(_ range: Range<Int>) -> Double {
        let uppercase = range.filter { characters[$0].isUppercase }.count
        if uppercase == 0 { return 0 }
        if uppercase == range.count || (uppercase == 1 && characters[range.lowerBound].isUppercase) { return 1 }
        return Double(uppercase)
    }

    // MARK: Sequences (abcd, 1234, 9876)

    private func sequenceMatches() -> [Match] {
        runs(minimumLength: PasswordStrengthTables.minimumRunLength) { previous, next in
            guard
                let lhs = previous.asciiValue, let rhs = next.asciiValue,
                Self.sequenceClass(lhs) != nil, Self.sequenceClass(lhs) == Self.sequenceClass(rhs)
            else { return nil }
            let delta = Int(rhs) - Int(lhs)
            return abs(delta) == 1 ? delta : nil
        }
        .map { range in
            let size = characters[range.lowerBound].asciiValue.flatMap(Self.sequenceClass) ?? 1
            let bits = log2(Double(size)) + PasswordStrengthTables.directionBits + log2(Double(range.count))
            return Match(start: range.lowerBound, end: range.upperBound, bits: bits, pattern: .sequence)
        }
    }

    /// Alphabet size of an ASCII byte's sequence class (lowercase, uppercase or digits).
    private static func sequenceClass(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"):
            PasswordStrengthTables.lettersInAlphabet
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            PasswordStrengthTables.decimalDigits
        default:
            nil
        }
    }

    /// Maximal runs where `step(previous, next)` returns the same non-nil value throughout.
    private func runs(minimumLength: Int, step: (Character, Character) -> Int?) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        var currentStep: Int?
        for index in 1..<max(characters.count, 1) {
            let value = step(characters[index - 1], characters[index])
            if value == nil || value != currentStep {
                if index - start >= minimumLength, currentStep != nil {
                    result.append(start..<index)
                }
                start = value == nil ? index : index - 1
                currentStep = value
            }
        }
        if characters.count - start >= minimumLength, currentStep != nil {
            result.append(start..<characters.count)
        }
        return result
    }

    // MARK: Keyboard rows (qwerty, asdf)

    private func keyboardMatches() -> [Match] {
        var matches: [Match] = []
        let keyBits = log2(Double(PasswordStrengthTables.keyboardKeyCount))
        for row in PasswordStrengthTables.keyboardRows {
            for direction in [row, Array(row.reversed())] {
                matches += rowMatches(in: direction, keyBits: keyBits)
            }
        }
        return matches
    }

    private func rowMatches(in row: [Character], keyBits: Double) -> [Match] {
        var matches: [Match] = []
        var start = 0
        while start < lowered.count {
            guard let rowIndex = row.firstIndex(of: lowered[start]) else {
                start += 1
                continue
            }
            var length = 1
            while start + length < lowered.count, rowIndex + length < row.count,
                  lowered[start + length] == row[rowIndex + length] {
                length += 1
            }
            if length >= PasswordStrengthTables.minimumKeyboardRunLength {
                let bits = keyBits + PasswordStrengthTables.directionBits + log2(Double(length))
                matches.append(Match(start: start, end: start + length, bits: bits, pattern: .keyboardPattern))
            }
            start += max(length, 1)
        }
        return matches
    }

    // MARK: Repeats (aaaa, abcabc)

    private func repeatMatches() -> [Match] {
        var matches: [Match] = []
        let count = characters.count
        for period in 1...max(count / 2, 1) {
            var start = 0
            while start + period < count {
                var end = start + period
                while end < count, lowered[end] == lowered[end - period] {
                    end += 1
                }
                let length = end - start
                let repetitions = length / period
                if repetitions >= 2, length >= PasswordStrengthTables.minimumRunLength {
                    let covered = repetitions * period
                    let bits = Double(period) * characterBits + log2(Double(repetitions))
                    matches.append(Match(start: start, end: start + covered, bits: bits, pattern: .repetition))
                    start += covered
                } else {
                    start += 1
                }
            }
        }
        return matches
    }

    // MARK: Years (1900-2099)

    private func yearMatches() -> [Match] {
        let length = PasswordStrengthTables.yearDigits
        guard characters.count >= length else { return [] }
        var matches: [Match] = []
        for start in 0...(characters.count - length) {
            let text = String(characters[start..<(start + length)])
            guard let year = Int(text), PasswordStrengthTables.yearRange.contains(year) else { continue }
            let bits = log2(Double(PasswordStrengthTables.yearRange.count))
            matches.append(Match(start: start, end: start + length, bits: bits, pattern: .year))
        }
        return matches
    }

    // MARK: Character pool

    private static func poolSize(of characters: [Character]) -> Int {
        var hasLower = false
        var hasUpper = false
        var hasDigit = false
        var hasSymbol = false
        var hasOther = false
        for character in characters {
            if let ascii = character.asciiValue {
                switch ascii {
                case UInt8(ascii: "a")...UInt8(ascii: "z"): hasLower = true
                case UInt8(ascii: "A")...UInt8(ascii: "Z"): hasUpper = true
                case UInt8(ascii: "0")...UInt8(ascii: "9"): hasDigit = true
                default: hasSymbol = true
                }
            } else {
                hasOther = true
            }
        }
        var size = 0
        if hasLower { size += PasswordStrengthTables.lettersInAlphabet }
        if hasUpper { size += PasswordStrengthTables.lettersInAlphabet }
        if hasDigit { size += PasswordStrengthTables.decimalDigits }
        if hasSymbol { size += PasswordStrengthTables.asciiSymbols }
        if hasOther { size += PasswordStrengthTables.nonASCIIPool }
        return max(size, PasswordStrengthTables.decimalDigits)
    }
}

// MARK: - Tables

/// Internal (not private) so tests can build worst-case inputs from the same tables.
enum PasswordStrengthTables {
    static let lettersInAlphabet = 26
    static let decimalDigits = 10
    /// Printable ASCII symbols, including space.
    static let asciiSymbols = 33
    /// Conservative pool for characters outside ASCII (accented letters, other scripts, emoji).
    static let nonASCIIPool = 100
    /// One bit for the direction of a sequence or keyboard run.
    static let directionBits = 1.0
    /// Shortest sequence or repeat counted as a pattern.
    static let minimumRunLength = 3
    /// Shortest keyboard run counted as a pattern.
    static let minimumKeyboardRunLength = 4
    static let yearDigits = 4
    /// Longest prefix searched for patterns (the search is quadratic).
    static let maxAnalyzedCharacters = 256
    static let yearRange = 1900...2099
    static let keyboardRows: [[Character]] = ["qwertyuiop", "asdfghjkl", "zxcvbnm", "1234567890"].map(Array.init)
    static let keyboardKeyCount = keyboardRows.reduce(0) { $0 + $1.count }

    /// Common substitutions: the typed character on the left may stand for any letter on the right.
    static let substitutions: [Character: Set<Character>] = [
        "@": ["a"], "4": ["a"], "8": ["b"], "(": ["c"], "3": ["e"], "6": ["g"], "9": ["g"],
        "1": ["i", "l"], "!": ["i", "l"], "|": ["i", "l"], "0": ["o"], "$": ["s"], "5": ["s"],
        "7": ["t"], "+": ["t"], "2": ["z"],
    ]

    /// Base words of the most common leaked passwords (lowercase, 4+ letters), plus product names.
    static let commonWords: [[Character]] = [
        "password", "passwd", "passw0rd", "qwerty", "admin", "administrator", "welcome", "letmein",
        "login", "master", "secret", "monkey", "dragon", "football", "baseball", "soccer", "hockey",
        "basketball", "iloveyou", "love", "lovely", "princess", "sunshine", "shadow", "superman",
        "batman", "spiderman", "starwars", "pokemon", "michael", "jennifer", "jordan", "thomas",
        "charlie", "daniel", "jessica", "ashley", "hunter", "ranger", "killer", "trustno1", "access",
        "flower", "summer", "winter", "spring", "autumn", "freedom", "whatever", "nothing", "hello",
        "computer", "internet", "google", "apple", "samsung", "microsoft", "github", "gitlab",
        "facebook", "twitter", "instagram", "cheese", "cookie", "chocolate", "banana", "orange",
        "purple", "silver", "golden", "diamond", "matrix", "mustang", "corvette", "ferrari",
        "harley", "guitar", "music", "angel", "devil", "jesus", "christ", "heaven", "family",
        "friend", "friends", "forever", "blessed", "happy", "lucky", "money", "mother", "father",
        "sister", "brother", "baby", "babygirl", "angels", "pepper", "ginger", "tigger", "buster",
        "maggie", "bailey", "secure", "security", "default", "changeme", "test", "testing", "guest",
        "user", "root", "abcd", "qazwsx", "zaq1", "asdf", "zxcv", "1q2w3e", "vault", "fxvault",
        "fractalx", "dubai", "emirates", "habibi", "yalla", "contrasena", "clave", "senha",
    ].map(Array.init)

    /// ``commonWords`` grouped by first letter, so matching only tries plausible words.
    static let commonWordsByFirstLetter: [Character: [[Character]]] = Dictionary(
        grouping: commonWords.filter { !$0.isEmpty },
        by: { $0[0] }
    )
}
