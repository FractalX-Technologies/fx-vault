import VaultCore

/// How ``DotEnvSerializer`` writes one value.
public enum DotEnvQuoting: String, Sendable, Hashable, CaseIterable {
    /// `KEY=value`: only for non-empty values made of `[A-Za-z0-9_./:@%+,=~-]`.
    case none
    /// `KEY='value'`: literal, may span lines. Used when the value has no `'` and no `\r`.
    case single
    /// `KEY="value"` with `\\`, `\"`, `\n`, `\r` and `\${` escaped.
    case double
}

/// Errors from ``DotEnvSerializer``. None of them carries a value.
public enum DotEnvSerializeError: Error, Sendable, Hashable {
    /// The key is not a portable `.env` key (`[A-Za-z_][A-Za-z0-9_]*`).
    case invalidKey(String)
    /// The same key appears twice.
    case duplicateKey(String)
    /// The value for this key is not valid UTF-8.
    case invalidValueEncoding(key: String)
    /// A header comment contains a line break.
    case invalidComment
}

/// One part of a serialized `.env` text: its `# ` comment lines, then its entries.
public struct DotEnvSectionModel: Sendable {
    public let comments: [String]
    public let entries: [DotEnvEntryModel]

    public init(comments: [String], entries: [DotEnvEntryModel]) {
        self.comments = comments
        self.entries = entries
    }
}

/// Writes `.env` files that ``DotEnvParser`` reads back exactly: `parse(serialize(x)) == x`.
///
/// Each value gets the plainest quoting that round-trips (``DotEnvQuoting``), which also keeps
/// the file readable by common dotenv loaders: values with `$`, `#`, quotes or whitespace are
/// quoted, single quotes (literal everywhere) are preferred, and double quotes are used only for
/// values that contain `'` or `\r`.
///
/// The output is built in a ``SecretBytes`` buffer sized up front, so no value is copied into
/// a growable `String` or `Array`. The caller writes it with ``SecureFileWriter`` and wipes it.
public enum DotEnvSerializer {
    private static let commentPrefix = Array("# ".utf8)

    /// How one entry is written, measured before the buffer is allocated.
    private struct EntryPlan {
        let entry: DotEnvEntryModel
        let quoting: DotEnvQuoting
        let length: Int
    }

    /// Serializes `entries` in order, after optional `# ` header comment lines.
    public static func serialize(
        _ entries: [DotEnvEntryModel],
        headerComments: [String] = []
    ) throws(DotEnvSerializeError) -> SecretBytes {
        try serialize(sections: [DotEnvSectionModel(comments: headerComments, entries: entries)])
    }

    /// Serializes `sections` in order with a blank line between two (Copy All's `# Secrets · N`
    /// and `# Variables · N`). Keys are unique within a section, so a secret and a variable may
    /// share a name.
    public static func serialize(sections: [DotEnvSectionModel]) throws(DotEnvSerializeError) -> SecretBytes {
        var planned: [(comments: [String], entries: [EntryPlan])] = []
        var length = max(sections.count - 1, 0)
        for section in sections {
            let plans = try plan(section)
            length += section.comments.reduce(0) { total, comment in
                total + commentPrefix.count + comment.utf8.count + 1
            }
            length += plans.reduce(0) { total, plan in
                // KEY + "=" + encoded value + "\n"
                total + plan.entry.key.utf8.count + 1 + plan.length + 1
            }
            planned.append((section.comments, plans))
        }

        let output = SecretBytes(count: length)
        output.withUnsafeMutableBytes { buffer in
            var writer = ByteWriter(buffer: buffer)
            for (index, section) in planned.enumerated() {
                if index > 0 {
                    writer.append(ASCII.lineFeed)
                }
                for comment in section.comments {
                    writer.append(commentPrefix)
                    writer.append(comment.utf8)
                    writer.append(ASCII.lineFeed)
                }
                for plan in section.entries {
                    writer.append(plan.entry.key.utf8)
                    writer.append(ASCII.equals)
                    plan.entry.value.withUnsafeBytes { bytes in
                        writer.appendValue(bytes, quoting: plan.quoting)
                    }
                    writer.append(ASCII.lineFeed)
                }
            }
        }
        return output
    }

    private static func plan(_ section: DotEnvSectionModel) throws(DotEnvSerializeError) -> [EntryPlan] {
        for comment in section.comments where comment.contains(where: \.isNewline) {
            throw .invalidComment
        }
        var seenKeys = Set<String>()
        var plans: [EntryPlan] = []
        for entry in section.entries {
            guard isPortableKey(entry.key) else { throw .invalidKey(entry.key) }
            guard seenKeys.insert(entry.key).inserted else { throw .duplicateKey(entry.key) }
            let analysis = entry.value.withUnsafeBytes { bytes in
                let style = quoting(for: bytes)
                return (
                    isValid: ByteScanning.isValidUTF8(bytes),
                    quoting: style,
                    length: encodedLength(of: bytes, quoting: style)
                )
            }
            guard analysis.isValid else { throw .invalidValueEncoding(key: entry.key) }
            plans.append(EntryPlan(entry: entry, quoting: analysis.quoting, length: analysis.length))
        }
        return plans
    }

    /// The quoting ``serialize(_:headerComments:)`` uses for `value`.
    public static func quoting(for value: SecretBytes) -> DotEnvQuoting {
        value.withUnsafeBytes { quoting(for: $0) }
    }

    /// True for keys every dotenv loader accepts: `[A-Za-z_][A-Za-z0-9_]*`.
    public static func isPortableKey(_ key: String) -> Bool {
        guard let first = key.utf8.first, ASCII.isLetter(first) || first == ASCII.underscore else {
            return false
        }
        return key.utf8.allSatisfy { ASCII.isAlphanumeric($0) || $0 == ASCII.underscore }
    }

    // MARK: - Quoting

    static func quoting(for value: UnsafeRawBufferPointer) -> DotEnvQuoting {
        // An empty value is written as `KEY=`.
        if value.allSatisfy(isUnquotedSafe) {
            return .none
        }
        if !value.contains(ASCII.singleQuote), !value.contains(ASCII.carriageReturn) {
            return .single
        }
        return .double
    }

    /// Bytes that need no quoting anywhere in a dotenv value.
    private static func isUnquotedSafe(_ byte: UInt8) -> Bool {
        if ASCII.isAlphanumeric(byte) { return true }
        switch byte {
        case ASCII.underscore, ASCII.period, ASCII.slash, ASCII.colon, ASCII.at, ASCII.hyphen,
             UInt8(ascii: "%"), UInt8(ascii: "+"), UInt8(ascii: ","), ASCII.equals, UInt8(ascii: "~"):
            return true
        default:
            return false
        }
    }

    private static func encodedLength(of value: UnsafeRawBufferPointer, quoting: DotEnvQuoting) -> Int {
        let quoteCount = 2
        switch quoting {
        case .none:
            return value.count
        case .single:
            return value.count + quoteCount
        case .double:
            var length = quoteCount
            for index in value.indices {
                length += needsEscape(value, at: index) ? 2 : 1
            }
            return length
        }
    }

    /// True when the byte at `index` is written as a two-byte escape inside double quotes.
    fileprivate static func needsEscape(_ value: UnsafeRawBufferPointer, at index: Int) -> Bool {
        switch value[index] {
        case ASCII.backslash, ASCII.doubleQuote, ASCII.lineFeed, ASCII.carriageReturn:
            true
        case ASCII.dollar:
            index + 1 < value.count && value[index + 1] == ASCII.openBrace
        default:
            false
        }
    }
}

/// Appends bytes into a buffer sized exactly by ``DotEnvSerializer``.
private struct ByteWriter {
    let buffer: UnsafeMutableRawBufferPointer
    private var index = 0

    init(buffer: UnsafeMutableRawBufferPointer) {
        self.buffer = buffer
    }

    mutating func append(_ byte: UInt8) {
        buffer[index] = byte
        index += 1
    }

    mutating func append(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            append(byte)
        }
    }

    mutating func appendValue(_ value: UnsafeRawBufferPointer, quoting: DotEnvQuoting) {
        switch quoting {
        case .none:
            append(value)
        case .single:
            append(ASCII.singleQuote)
            append(value)
            append(ASCII.singleQuote)
        case .double:
            append(ASCII.doubleQuote)
            for index in value.indices {
                let byte = value[index]
                guard DotEnvSerializer.needsEscape(value, at: index) else {
                    append(byte)
                    continue
                }
                append(ASCII.backslash)
                switch byte {
                case ASCII.lineFeed: append(ASCII.letterN)
                case ASCII.carriageReturn: append(ASCII.letterR)
                default: append(byte)
                }
            }
            append(ASCII.doubleQuote)
        }
    }
}
