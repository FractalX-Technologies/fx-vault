import Foundation
import VaultCore

/// A JSON value to send (v0.8.0). ``secret(_:)`` holds a value, which the writer copies straight
/// from its buffer into the body, escaped, so it never becomes a Swift `String`.
indirect enum JSONBodyValue: Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    /// A value-free string (a name, a type, an environment).
    case string(String)
    /// A value. Must be valid UTF-8.
    case secret(SecretBytes)
    case array([JSONBodyValue])
    /// Members in order; keys must be unique.
    case object([JSONBodyMember])

    /// An object from ordered `key: value` pairs.
    static func members(_ pairs: KeyValuePairs<String, JSONBodyValue>) -> JSONBodyValue {
        .object(pairs.map { JSONBodyMember($0.key, $0.value) })
    }

    /// An array of value-free strings.
    static func strings(_ values: [String]) -> JSONBodyValue {
        .array(values.map(JSONBodyValue.string))
    }
}

/// One `key: value` member of a ``JSONBodyValue/object(_:)``.
struct JSONBodyMember: Sendable {
    let key: String
    let value: JSONBodyValue

    init(_ key: String, _ value: JSONBodyValue) {
        self.key = key
        self.value = value
    }
}

/// Writes a ``JSONBodyValue`` as compact JSON (RFC 8259) directly into `SecretBytes`.
///
/// Strings are escaped as RFC 8259 requires: `"` and `\` with a backslash; `\b`, `\f`, `\n`,
/// `\r`, `\t` by name; every other control character below U+0020 as `\u00XX`. Everything else,
/// including non-ASCII text and emoji, is written as UTF-8. Members keep their order and there
/// is no whitespace, so a body is deterministic.
enum JSONBodyWriter {
    /// Deepest nesting written. Local choice; request bodies are at most three levels deep.
    static let maxDepth = 16


    private static let unicodeEscapePrefix = "\\u00"
    private static let hexDigits = Array("0123456789abcdef".utf8)
    private static let nibbleShift: UInt8 = 4
    private static let nibbleMask: UInt8 = 0x0F

    /// The body as `SecretBytes`. Throws ``DestinationError/valueNotUTF8`` when a secret is not
    /// valid UTF-8. Nesting deeper than ``maxDepth`` and duplicate keys are programming errors,
    /// reported as ``DestinationError/invalidRequest(code:)`` with no code.
    static func encode(_ value: JSONBodyValue) throws(DestinationError) -> SecretBytes {
        let buffer = SecretByteBuffer()
        try write(value, to: buffer, depth: 0)
        return buffer.makeSecretBytes()
    }

    private static func write(_ value: JSONBodyValue, to buffer: SecretByteBuffer, depth: Int) throws(DestinationError) {
        guard depth <= maxDepth else { throw .invalidRequest(code: nil) }
        switch value {
        case .null:
            buffer.append(utf8: "null")
        case .bool(let flag):
            buffer.append(utf8: flag ? "true" : "false")
        case .integer(let number):
            buffer.append(utf8: String(number))
        case .string(let text):
            var copy = text
            copy.withUTF8 { appendString(UnsafeRawBufferPointer($0), to: buffer) }
        case .secret(let secret):
            try secret.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) throws(DestinationError) in
                guard UTF8Validation.isValid(bytes) else { throw .valueNotUTF8 }
                appendString(bytes, to: buffer)
            }
        case .array(let elements):
            buffer.append(JSONByte.openBracket)
            for (index, element) in elements.enumerated() {
                if index > 0 { buffer.append(JSONByte.comma) }
                try write(element, to: buffer, depth: depth + 1)
            }
            buffer.append(JSONByte.closeBracket)
        case .object(let members):
            guard Set(members.map(\.key)).count == members.count else { throw .invalidRequest(code: nil) }
            buffer.append(JSONByte.openBrace)
            for (index, member) in members.enumerated() {
                if index > 0 { buffer.append(JSONByte.comma) }
                var key = member.key
                key.withUTF8 { appendString(UnsafeRawBufferPointer($0), to: buffer) }
                buffer.append(JSONByte.colon)
                try write(member.value, to: buffer, depth: depth + 1)
            }
            buffer.append(JSONByte.closeBrace)
        }
    }

    /// Writes `bytes` (valid UTF-8) as a quoted, escaped JSON string.
    static func appendString(_ bytes: UnsafeRawBufferPointer, to buffer: SecretByteBuffer) {
        buffer.append(JSONByte.quote)
        for byte in bytes {
            switch byte {
            case JSONByte.quote, JSONByte.backslash:
                buffer.append(JSONByte.backslash)
                buffer.append(byte)
            case JSONByte.backspace: appendNamedEscape(JSONByte.lowercaseB, to: buffer)
            case JSONByte.formFeed: appendNamedEscape(JSONByte.lowercaseF, to: buffer)
            case JSONByte.lineFeed: appendNamedEscape(JSONByte.lowercaseN, to: buffer)
            case JSONByte.carriageReturn: appendNamedEscape(JSONByte.lowercaseR, to: buffer)
            case JSONByte.tab: appendNamedEscape(JSONByte.lowercaseT, to: buffer)
            case ..<JSONByte.firstPrintable:
                buffer.append(utf8: unicodeEscapePrefix)
                buffer.append(hexDigits[Int(byte >> nibbleShift)])
                buffer.append(hexDigits[Int(byte & nibbleMask)])
            default:
                buffer.append(byte)
            }
        }
        buffer.append(JSONByte.quote)
    }

    private static func appendNamedEscape(_ letter: UInt8, to buffer: SecretByteBuffer) {
        buffer.append(JSONByte.backslash)
        buffer.append(letter)
    }
}
