import Foundation
import VaultCore

/// Why a key or value looks like a credential (§5.13).
public enum CredentialReason: Sendable, Hashable {
    /// The uppercased key contains this pattern (for example `TOKEN`).
    case keyContains(String)
    /// The value contains a URL with userinfo (`scheme://user:password@host`, user may be empty).
    case urlWithCredentials
    /// The value contains a PEM block (`-----BEGIN ...-----`).
    case pemBlock
    /// The value contains a JSON Web Token (`eyJ...`, three base64url segments).
    case jsonWebToken
    /// The value contains a known token format starting with this prefix (for example `ghp_`).
    case knownTokenPrefix(String)
    /// The value is one long random-looking token (Shannon entropy at or above the threshold).
    case highEntropy
}

/// The verdict of ``CredentialClassifier``: the reasons found, in a stable order (key first,
/// then value checks).
public struct CredentialAssessmentModel: Sendable, Hashable {
    public let reasons: [CredentialReason]

    public init(reasons: [CredentialReason]) {
        self.reasons = reasons
    }

    /// No reason found.
    public static let none = CredentialAssessmentModel(reasons: [])

    /// True when the item should be pre-marked as a secret, and when preflight should ask for
    /// confirmation before pushing it as a variable.
    public var isLikelyCredential: Bool {
        !reasons.isEmpty
    }

    /// The kind import pre-selects.
    public var suggestedKind: ConfigKind {
        isLikelyCredential ? .secret : .variable
    }
}

/// Pre-marks secrets and flags credential-looking variables (§5.13, M3/M5).
///
/// A key matches when its uppercase form **contains** one of ``keyPatterns`` (a deliberately
/// broad rule: a false positive only pre-marks a secret). A value matches when it contains URL
/// userinfo, a PEM block, a JWT, a known token prefix, or when it is a single token of at least
/// ``EnvToolsLimits/entropyMinimumLength`` printable ASCII characters, mixing at least
/// ``EnvToolsLimits/entropyMinimumCharacterClasses`` of lowercase/uppercase/digits, without
/// `://`, with entropy of at least ``EnvToolsLimits/entropyThresholdBitsPerCharacter`` bits per
/// character.
///
/// Values are inspected in place (``SecretBytes`` or a `String`'s UTF-8 storage); nothing is
/// copied or stored.
public enum CredentialClassifier {
    /// Key fragments: the spec list (TOKEN, KEY, PASSWORD, SECRET, PRIVATE) plus §5.13's
    /// additions. Order matters: the first match is the one reported.
    public static let keyPatterns = [
        "TOKEN", "KEY", "PASSWORD", "SECRET", "PRIVATE",
        "PASS", "PWD", "CREDENTIAL", "AUTH", "DSN", "CERT", "PEM", "SIGNING", "WEBHOOK",
    ]

    /// A token format recognised by its prefix.
    public struct TokenPrefix: Sendable, Hashable {
        /// Characters allowed after the prefix.
        public enum Alphabet: Sendable, Hashable {
            /// `[A-Za-z0-9_]`
            case alphanumericUnderscore
            /// `[A-Za-z0-9]`
            case alphanumeric
            /// `[A-Z0-9]`
            case uppercaseAlphanumeric
            /// `[A-Za-z0-9-]`
            case alphanumericHyphen
        }

        public let prefix: String
        public let alphabet: Alphabet
        public let minimumTailLength: Int
    }

    /// Known token prefixes: §5.13 (`ghp_`, `github_pat_`, `sk_live_`, `AKIA`, `xoxb-`, `xoxp-`)
    /// plus the other GitHub token types the StderrRedactor already treats as tokens (§4.5).
    public static let tokenPrefixes: [TokenPrefix] = {
        let gitHub = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"].map {
            TokenPrefix(
                prefix: $0,
                alphabet: .alphanumericUnderscore,
                minimumTailLength: EnvToolsLimits.gitHubTokenMinimumTailLength
            )
        }
        return gitHub + [
            TokenPrefix(
                prefix: "github_pat_",
                alphabet: .alphanumericUnderscore,
                minimumTailLength: EnvToolsLimits.gitHubTokenMinimumTailLength
            ),
            TokenPrefix(
                prefix: "sk_live_",
                alphabet: .alphanumeric,
                minimumTailLength: EnvToolsLimits.stripeKeyMinimumTailLength
            ),
            TokenPrefix(
                prefix: "AKIA",
                alphabet: .uppercaseAlphanumeric,
                minimumTailLength: EnvToolsLimits.awsAccessKeyTailLength
            ),
            TokenPrefix(
                prefix: "xoxb-",
                alphabet: .alphanumericHyphen,
                minimumTailLength: EnvToolsLimits.slackTokenMinimumTailLength
            ),
            TokenPrefix(
                prefix: "xoxp-",
                alphabet: .alphanumericHyphen,
                minimumTailLength: EnvToolsLimits.slackTokenMinimumTailLength
            ),
        ]
    }()

    private static let schemeSeparator = Array("://".utf8)
    private static let pemBegin = Array("-----BEGIN ".utf8)
    private static let pemDashes = Array("-----".utf8)
    private static let jwtHeaderStart = Array("eyJ".utf8)
    private static let byteValueCount = 256

    // MARK: - Assessment

    /// Key and value checks combined. Pass nil when the value is unknown (value-missing items).
    public static func assess(key: String, value: SecretBytes?) -> CredentialAssessmentModel {
        let valueReasons = value.map { secret in secret.withUnsafeBytes { reasons(inValue: $0) } } ?? []
        return CredentialAssessmentModel(reasons: keyReasons(for: key) + valueReasons)
    }

    /// Key and value checks for a value held as a `String` (the editor's own copy, §5.12).
    public static func assess(key: String, value: String) -> CredentialAssessmentModel {
        CredentialAssessmentModel(reasons: keyReasons(for: key) + valueReasons(in: value))
    }

    /// The key check alone: the first of ``keyPatterns`` the uppercase key contains.
    public static func keyReasons(for key: String) -> [CredentialReason] {
        let uppercased = key.uppercased()
        guard let pattern = keyPatterns.first(where: { uppercased.contains($0) }) else { return [] }
        return [.keyContains(pattern)]
    }

    /// The value checks alone.
    public static func valueReasons(in value: SecretBytes) -> [CredentialReason] {
        value.withUnsafeBytes { reasons(inValue: $0) }
    }

    /// The value checks alone, reading the string's UTF-8 storage in place.
    public static func valueReasons(in value: String) -> [CredentialReason] {
        var text = value
        return text.withUTF8 { reasons(inValue: UnsafeRawBufferPointer($0)) }
    }

    /// Shannon entropy of `bytes`, in bits per byte (0 for an empty buffer).
    public static func shannonEntropy(of bytes: UnsafeRawBufferPointer) -> Double {
        guard !bytes.isEmpty else { return 0 }
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: byteValueCount) { counts in
            counts.initialize(repeating: 0)
            defer { counts.update(repeating: 0) }
            for byte in bytes {
                counts[Int(byte)] += 1
            }
            let total = Double(bytes.count)
            return counts.reduce(0.0) { entropy, count in
                guard count > 0 else { return entropy }
                let probability = Double(count) / total
                return entropy - probability * log2(probability)
            }
        }
    }

    // MARK: - Value heuristics

    static func reasons(inValue bytes: UnsafeRawBufferPointer) -> [CredentialReason] {
        var reasons: [CredentialReason] = []
        if containsURLUserinfo(bytes) { reasons.append(.urlWithCredentials) }
        if containsPEMBlock(bytes) { reasons.append(.pemBlock) }
        if containsJWT(bytes) { reasons.append(.jsonWebToken) }
        if let prefix = tokenPrefixes.first(where: { contains($0, in: bytes) }) {
            reasons.append(.knownTokenPrefix(prefix.prefix))
        }
        if isHighEntropyToken(bytes) { reasons.append(.highEntropy) }
        return reasons
    }

    /// `://` followed by `[^/@\s]*:[^/@\s]+@` (§5.13's pattern, with an empty user allowed for
    /// `redis://:password@host`, and whitespace ending the authority).
    static func containsURLUserinfo(_ bytes: UnsafeRawBufferPointer) -> Bool {
        ByteScanning.occurrences(of: schemeSeparator, in: bytes).contains { start in
            var index = start + schemeSeparator.count
            var firstColon: Int?
            while index < bytes.count {
                let byte = bytes[index]
                if byte == ASCII.at {
                    guard let colon = firstColon else { return false }
                    return colon < index - 1
                }
                if byte == ASCII.slash || ASCII.isWhitespace(byte) { return false }
                if byte == ASCII.colon, firstColon == nil { firstColon = index }
                index += 1
            }
            return false
        }
    }

    /// `-----BEGIN ` + `[A-Z0-9 ]+` + `-----`.
    static func containsPEMBlock(_ bytes: UnsafeRawBufferPointer) -> Bool {
        ByteScanning.occurrences(of: pemBegin, in: bytes).contains { start in
            var index = start + pemBegin.count
            let labelStart = index
            while index < bytes.count,
                  ASCII.isUppercaseLetter(bytes[index]) || ASCII.isDigit(bytes[index]) || bytes[index] == ASCII.space {
                index += 1
            }
            return index > labelStart && ByteScanning.matches(pemDashes, in: bytes, at: index)
        }
    }

    /// `eyJ` at a token boundary, then `<header>.<payload>.<signature>` in base64url (the
    /// signature may be empty, as with `alg: none`).
    static func containsJWT(_ bytes: UnsafeRawBufferPointer) -> Bool {
        ByteScanning.occurrences(of: jwtHeaderStart, in: bytes).contains { start in
            if start > 0, ASCII.isBase64URL(bytes[start - 1]) { return false }
            let headerEnd = base64URLRunEnd(in: bytes, from: start)
            guard headerEnd - start >= EnvToolsLimits.jwtMinimumHeaderLength,
                  headerEnd < bytes.count, bytes[headerEnd] == ASCII.period
            else { return false }
            let payloadStart = headerEnd + 1
            let payloadEnd = base64URLRunEnd(in: bytes, from: payloadStart)
            return payloadEnd - payloadStart >= EnvToolsLimits.jwtMinimumPayloadLength
                && payloadEnd < bytes.count && bytes[payloadEnd] == ASCII.period
        }
    }

    /// `prefix` at a token boundary followed by at least `minimumTailLength` allowed characters.
    static func contains(_ token: TokenPrefix, in bytes: UnsafeRawBufferPointer) -> Bool {
        let prefix = Array(token.prefix.utf8)
        return ByteScanning.occurrences(of: prefix, in: bytes).contains { start in
            if start > 0, ASCII.isAlphanumeric(bytes[start - 1]) { return false }
            var index = start + prefix.count
            while index < bytes.count, isAllowed(bytes[index], in: token.alphabet) {
                index += 1
            }
            return index - (start + prefix.count) >= token.minimumTailLength
        }
    }

    static func isHighEntropyToken(_ bytes: UnsafeRawBufferPointer) -> Bool {
        let token = UnsafeRawBufferPointer(rebasing: bytes[ByteScanning.trimmedRange(of: bytes)])
        guard token.count >= EnvToolsLimits.entropyMinimumLength,
              token.allSatisfy({ !ASCII.isWhitespace($0) && !ASCII.isControl($0) && $0 < ASCII.firstNonASCII }),
              !ByteScanning.contains(schemeSeparator, in: token)
        else { return false }
        let classes = [
            token.contains(where: ASCII.isLowercaseLetter),
            token.contains(where: ASCII.isUppercaseLetter),
            token.contains(where: ASCII.isDigit),
        ].filter { $0 }.count
        guard classes >= EnvToolsLimits.entropyMinimumCharacterClasses else { return false }
        return shannonEntropy(of: token) >= EnvToolsLimits.entropyThresholdBitsPerCharacter
    }

    private static func base64URLRunEnd(in bytes: UnsafeRawBufferPointer, from start: Int) -> Int {
        var index = start
        while index < bytes.count, ASCII.isBase64URL(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func isAllowed(_ byte: UInt8, in alphabet: TokenPrefix.Alphabet) -> Bool {
        switch alphabet {
        case .alphanumericUnderscore: ASCII.isAlphanumeric(byte) || byte == ASCII.underscore
        case .alphanumeric: ASCII.isAlphanumeric(byte)
        case .uppercaseAlphanumeric: ASCII.isUppercaseLetter(byte) || ASCII.isDigit(byte)
        case .alphanumericHyphen: ASCII.isAlphanumeric(byte) || byte == ASCII.hyphen
        }
    }
}
