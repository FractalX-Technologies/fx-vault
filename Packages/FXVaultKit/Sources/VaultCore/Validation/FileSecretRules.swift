import Foundation

/// File secrets (1.0 F1, boards Place-FileDrop and Place-FileSheet): what a file is, how its
/// bytes become a secret's value, and the name it suggests. Pure; the caller holds the bytes in
/// ``SecretBytes`` and wipes them. Limits apply to the stored value (after Base64).
public enum FileSecretRules {
    /// The extensions a place takes by drag and drop (Choose… opens any file).
    public static let droppableExtensions = ["p8", "pem", "json"]

    /// What the sheet shows about a file, measured once when the file is read.
    public struct FactsModel: Sendable, Hashable {
        public let byteCount: Int
        /// The size of the file in Base64.
        public let base64ByteCount: Int
        /// UTF-8 without a NUL byte, so it can be stored as Exact text.
        public let isText: Bool
        /// Lines of the text without its trailing line breaks; nil for a binary file.
        public let lineCount: Int?
        /// Trailing CR and LF bytes, which Exact text loses (D32).
        public let trailingLineBreakCount: Int

        public init(byteCount: Int, isText: Bool, lineCount: Int?, trailingLineBreakCount: Int) {
            self.byteCount = byteCount
            base64ByteCount = FileSecretRules.base64Count(byteCount)
            self.isText = isText
            self.lineCount = lineCount
            self.trailingLineBreakCount = trailingLineBreakCount
        }
    }

    /// True when a dropped file's extension is one a place takes (case-insensitive).
    public static func isDroppable(fileName: String) -> Bool {
        droppableExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    /// Measures `bytes` without copying them.
    public static func facts(of bytes: SecretBytes) -> FactsModel {
        bytes.withUnsafeBytes { buffer in
            let trailing = ValueNormalizer.trailingNewlineCount(in: buffer)
            let isText = isUTF8Text(buffer)
            let kept = UnsafeRawBufferPointer(rebasing: buffer[0..<(buffer.count - trailing)])
            let lines = kept.isEmpty ? 0 : kept.reduce(1) { $1 == lineFeed ? $0 + 1 : $0 }
            return FactsModel(
                byteCount: buffer.count,
                isText: isText,
                lineCount: isText ? lines : nil,
                trailingLineBreakCount: trailing
            )
        }
    }

    /// The encoding a file is stored with: Base64 for a binary file, whatever was chosen.
    public static func encoding(_ choice: FileSecretEncoding, for facts: FactsModel) -> FileSecretEncoding {
        facts.isText ? choice : .base64
    }

    /// The size of the stored value: Exact text loses its trailing line breaks, Base64 has none.
    public static func storedByteCount(of facts: FactsModel, as encoding: FileSecretEncoding) -> Int {
        switch self.encoding(encoding, for: facts) {
        case .text: facts.byteCount - facts.trailingLineBreakCount
        case .base64: facts.base64ByteCount
        }
    }

    /// The value to store for `bytes`, in a new buffer the caller wipes. Exact text keeps its
    /// trailing line breaks here; the repositories remove them (``ValueNormalizer``).
    public static func value(of bytes: SecretBytes, as encoding: FileSecretEncoding) -> SecretBytes {
        switch encoding {
        case .text: bytes.copy()
        case .base64: base64(bytes)
        }
    }

    /// The metadata kept with the item: the file's shown name (``fileName(_:)``), its lines and
    /// the stored encoding.
    public static func model(fileName: String, facts: FactsModel, encoding: FileSecretEncoding) -> FileSecretModel {
        FileSecretModel(
            fileName: self.fileName(fileName),
            lineCount: facts.lineCount,
            encoding: self.encoding(encoding, for: facts)
        )
    }

    /// A file's name as the sheet, the table and the notes show it: the last path component
    /// without control, bidi or invisible characters (as item names), cut to
    /// ``Limits/maxFileSecretNameLength`` scalars as the column's CHECK counts. Never empty.
    public static func fileName(_ path: String) -> String {
        let cleaned = UnicodeScalarPolicy.removingDisallowedAndInvisible(from: (path as NSString).lastPathComponent)
        let scalars = cleaned.unicodeScalars.prefix(Limits.maxFileSecretNameLength)
        let name = String(String.UnicodeScalarView(scalars))
        return name.isEmpty ? unnamedFile : name
    }

    /// The name kept for a file whose name has nothing visible left.
    static let unnamedFile = "file"

    // MARK: - Names

    /// A secret name from a file's name: the words of its name (camel case split), any later
    /// part holding a digit left out (a key id such as ABC123), then the extension, so
    /// `AuthKey_ABC123.p8` gives `AUTH_KEY_P8`. Nil when nothing valid remains.
    public static func suggestedName(forFileName fileName: String) -> String? {
        let name = (fileName as NSString).lastPathComponent
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let stem = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        let parts = asciiAlphanumericRuns(in: stem)
        let kept = parts.enumerated().filter { index, part in
            index == 0 || !part.contains(where: \.isNumber)
        }
        var words = kept.flatMap { camelCaseWords(in: $0.element) }
        words += asciiAlphanumericRuns(in: fileExtension)
        guard !words.isEmpty else { return nil }
        let candidate = words.joined(separator: "_").uppercased()
        return GitHubNameValidator.isValid(candidate) ? candidate : GitHubNameValidator.suggestedFix(for: candidate)
    }

    /// The runs of ASCII letters and digits in `text`.
    private static func asciiAlphanumericRuns(in text: String) -> [String] {
        text.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
    }

    /// `AuthKey` → Auth, Key; `APNSKey` → APNS, Key; `key2` stays one word.
    private static func camelCaseWords(in run: String) -> [String] {
        let characters = Array(run)
        var words: [String] = []
        var current = ""
        for (index, character) in characters.enumerated() {
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let startsWord = character.isUppercase && (
                previous?.isLowercase == true || previous?.isNumber == true
                    || (previous?.isUppercase == true && next?.isLowercase == true)
            )
            if startsWord, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    // MARK: - Bytes

    private static let lineFeed = UInt8(ascii: "\n")
    private static let padding = UInt8(ascii: "=")
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    /// The length of `count` bytes in padded Base64.
    public static func base64Count(_ count: Int) -> Int {
        (max(count, 0) + 2) / 3 * 4
    }

    /// Padded Base64 (RFC 4648, one line) of `bytes`, written straight into a new buffer so the
    /// file's content never sits in an unwipeable `Data` or `String`.
    public static func base64(_ bytes: SecretBytes) -> SecretBytes {
        let output = SecretBytes(count: base64Count(bytes.count))
        bytes.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                var read = 0
                var written = 0
                while read < input.count {
                    let available = min(3, input.count - read)
                    var group: UInt32 = 0
                    for offset in 0..<3 {
                        group <<= 8
                        if offset < available {
                            group |= UInt32(input[read + offset])
                        }
                    }
                    for offset in 0..<4 {
                        let shift = UInt32(18 - 6 * offset)
                        out[written + offset] = offset <= available ? alphabet[Int((group >> shift) & 0x3F)] : padding
                    }
                    read += 3
                    written += 4
                }
            }
        }
        return output
    }

    /// Valid UTF-8 with no NUL byte (a NUL is a sure sign of a binary file).
    private static func isUTF8Text(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard !bytes.contains(0) else { return false }
        var iterator = bytes.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }
}
