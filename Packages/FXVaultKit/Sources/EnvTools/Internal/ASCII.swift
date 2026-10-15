/// ASCII byte constants and byte-level helpers shared by the parser, serializer and classifier.
///
/// EnvTools works on UTF-8 bytes inside `SecretBytes` buffers, so values are never copied into
/// a `String` (§5.12).
enum ASCII {
    static let tab = UInt8(ascii: "\t")
    static let lineFeed = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let space = UInt8(ascii: " ")
    static let hash = UInt8(ascii: "#")
    static let equals = UInt8(ascii: "=")
    static let singleQuote = UInt8(ascii: "'")
    static let doubleQuote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let dollar = UInt8(ascii: "$")
    static let openBrace = UInt8(ascii: "{")
    static let underscore = UInt8(ascii: "_")
    static let hyphen = UInt8(ascii: "-")
    static let period = UInt8(ascii: ".")
    static let slash = UInt8(ascii: "/")
    static let colon = UInt8(ascii: ":")
    static let at = UInt8(ascii: "@")
    static let letterN = UInt8(ascii: "n")
    static let letterR = UInt8(ascii: "r")
    static let letterT = UInt8(ascii: "t")

    /// The last C0 control character (0x1F); 0x7F (DEL) is checked separately.
    static let lastControl: UInt8 = 0x1F
    static let delete: UInt8 = 0x7F
    /// Bytes at or above this value are not ASCII.
    static let firstNonASCII: UInt8 = 0x80

    /// The UTF-8 byte order mark.
    static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
    /// The start of a PEM begin line (`-----BEGIN CERTIFICATE-----`).
    static let pemBegin = Array("-----BEGIN ".utf8)
    /// The start of a PEM end line (`-----END CERTIFICATE-----`).
    static let pemEnd = Array("-----END ".utf8)

    static func isHorizontalWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == tab
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        isHorizontalWhitespace(byte) || byte == lineFeed || byte == carriageReturn
    }

    static func isControl(_ byte: UInt8) -> Bool {
        byte <= lastControl || byte == delete
    }

    static func isUppercaseLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    static func isLowercaseLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    static func isLetter(_ byte: UInt8) -> Bool {
        isUppercaseLetter(byte) || isLowercaseLetter(byte)
    }

    static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isLetter(byte) || isDigit(byte)
    }

    /// `[A-Za-z0-9_-]`: the base64url alphabet without padding.
    static func isBase64URL(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == underscore || byte == hyphen
    }
}

/// Byte-buffer helpers.
enum ByteScanning {
    /// True when `bytes` is well-formed UTF-8 (no copy is made).
    static func isValidUTF8(_ bytes: UnsafeRawBufferPointer) -> Bool {
        var iterator = bytes.makeIterator()
        var decoder = Unicode.UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue:
                continue
            case .emptyInput:
                return true
            case .error:
                return false
            }
        }
    }

    /// True when `pattern` occurs in `bytes` at `index`.
    static func matches(_ pattern: [UInt8], in bytes: UnsafeRawBufferPointer, at index: Int) -> Bool {
        guard index >= 0, index + pattern.count <= bytes.count else { return false }
        for (offset, byte) in pattern.enumerated() where bytes[index + offset] != byte {
            return false
        }
        return true
    }

    /// Every index where `pattern` starts in `bytes` (naive search; inputs are small).
    static func occurrences(of pattern: [UInt8], in bytes: UnsafeRawBufferPointer) -> [Int] {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return [] }
        return (0...(bytes.count - pattern.count)).filter { matches(pattern, in: bytes, at: $0) }
    }

    /// True when `pattern` occurs anywhere in `bytes`.
    static func contains(_ pattern: [UInt8], in bytes: UnsafeRawBufferPointer) -> Bool {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return false }
        return (0...(bytes.count - pattern.count)).contains { matches(pattern, in: bytes, at: $0) }
    }

    /// The range of `bytes` without leading and trailing ASCII whitespace.
    static func trimmedRange(of bytes: UnsafeRawBufferPointer) -> Range<Int> {
        var lower = 0
        var upper = bytes.count
        while lower < upper, ASCII.isWhitespace(bytes[lower]) { lower += 1 }
        while upper > lower, ASCII.isWhitespace(bytes[upper - 1]) { upper -= 1 }
        return lower..<upper
    }
}
