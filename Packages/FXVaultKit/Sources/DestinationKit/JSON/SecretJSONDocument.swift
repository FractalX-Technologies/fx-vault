import Foundation
import VaultCore

/// One step into a JSON document: an object key or an array index.
enum JSONPathComponent: Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case key(String)
    case index(Int)

    init(stringLiteral value: String) {
        self = .key(value)
    }

    init(integerLiteral value: Int) {
        self = .index(value)
    }
}

/// A JSON document read over a `SecretBytes` body without turning its strings into Swift
/// `String`s (v0.8.0): the secret JSON scanner.
///
/// Parsing validates the whole body against RFC 8259 (UTF-8, escapes, surrogate pairs, number
/// grammar, nesting up to ``maxDepth``, no duplicate keys, nothing after the root value) and
/// records only where each value is. Fields are then read on demand: ``secret(_:)`` unescapes a
/// string into new `SecretBytes`; ``string(_:)``, ``integer(_:)`` and ``bool(_:)`` are for
/// value-free fields (names, ids, timestamps). Object keys are decoded as `String`s.
///
/// Malformed input throws ``DestinationError/decoding``; it never traps. The document keeps a
/// reference to the body and does not wipe it: the caller wipes the body once done.
struct SecretJSONDocument: Sendable {
    /// Deepest nesting accepted. Local choice; provider answers are at most five levels deep.
    static let maxDepth = 64

    enum Kind: Sendable, Hashable {
        case object, array, string, number, bool, null
    }

    fileprivate indirect enum Node: Sendable {
        case object([String: Node])
        case array([Node])
        /// The bytes between the quotes, still escaped.
        case string(start: Int, end: Int, hasEscapes: Bool)
        case number(start: Int, end: Int)
        case bool(Bool)
        case null
    }

    private let source: SecretBytes
    private let node: Node

    /// Parses `body`. Throws ``DestinationError/decoding`` when it is not one valid JSON value.
    init(parsing body: SecretBytes) throws(DestinationError) {
        source = body
        node = try body.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) throws(DestinationError) -> Node in
            var parser = JSONParser(bytes: bytes)
            return try parser.parseDocument()
        }
    }

    private init(source: SecretBytes, node: Node) {
        self.source = source
        self.node = node
    }

    /// The top-level string field `name` of `body` as `SecretBytes` (for example a secret's
    /// `"value"`), or nil when it is missing or not a string. Throws when `body` is malformed.
    static func secretField(_ name: String, in body: SecretBytes) throws(DestinationError) -> SecretBytes? {
        try SecretJSONDocument(parsing: body).secret(.key(name))
    }

    // MARK: - Navigation

    /// The kind of this document's root value.
    var kind: Kind {
        switch node {
        case .object: .object
        case .array: .array
        case .string: .string
        case .number: .number
        case .bool: .bool
        case .null: .null
        }
    }

    /// The value at `path` as a document, or nil.
    func child(_ path: JSONPathComponent...) -> SecretJSONDocument? {
        resolve(path).map { SecretJSONDocument(source: source, node: $0) }
    }

    /// The elements of the array at `path`, or nil when it is not an array.
    func elements(_ path: JSONPathComponent...) -> [SecretJSONDocument]? {
        elements(at: path)
    }

    /// The keys of the object at `path`, or nil when it is not an object.
    func keys(_ path: JSONPathComponent...) -> Set<String>? {
        guard case .object(let members) = resolve(path) else { return nil }
        return Set(members.keys)
    }

    /// True when `path` leads to a value (`null` included).
    func contains(_ path: JSONPathComponent...) -> Bool {
        resolve(path) != nil
    }

    /// True when `path` leads to `null`.
    func isNull(_ path: JSONPathComponent...) -> Bool {
        guard case .null = resolve(path) else { return false }
        return true
    }

    // MARK: - Reading

    /// The string at `path`, unescaped into new `SecretBytes`, or nil when it is missing or not
    /// a string. The caller wipes the result.
    func secret(_ path: JSONPathComponent...) -> SecretBytes? {
        guard case .string(let start, let end, let hasEscapes) = resolve(path) else { return nil }
        return source.withUnsafeBytes { bytes -> SecretBytes? in
            let buffer = SecretByteBuffer(capacity: end - start)
            guard JSONParser.unescape(bytes, start: start, end: end, hasEscapes: hasEscapes, into: buffer) else {
                return nil
            }
            return buffer.makeSecretBytes()
        }
    }

    /// The string at `path` as a `String`, for value-free fields only (names, ids, types,
    /// links). Nil when it is missing or not a string.
    func string(_ path: JSONPathComponent...) -> String? {
        guard case .string(let start, let end, let hasEscapes) = resolve(path) else { return nil }
        return source.withUnsafeBytes { bytes in
            JSONParser.decodeString(bytes, start: start, end: end, hasEscapes: hasEscapes)
        }
    }

    /// The number at `path` when it is an integer that fits `Int64` (`1.7e12` counts when it is
    /// integral), else nil.
    func integer(_ path: JSONPathComponent...) -> Int64? {
        guard case .number(let start, let end) = resolve(path) else { return nil }
        return source.withUnsafeBytes { bytes in
            JSONParser.integer(bytes, start: start, end: end)
        }
    }

    /// The boolean at `path`, or nil.
    func bool(_ path: JSONPathComponent...) -> Bool? {
        guard case .bool(let flag) = resolve(path) else { return nil }
        return flag
    }

    /// The array of strings at `path` (value-free), or nil when it is not an array of strings.
    func strings(_ path: JSONPathComponent...) -> [String]? {
        guard let elements = elements(at: path) else { return nil }
        var result: [String] = []
        for element in elements {
            guard let text = element.string() else { return nil }
            result.append(text)
        }
        return result
    }

    private func elements(at path: [JSONPathComponent]) -> [SecretJSONDocument]? {
        guard case .array(let nodes) = resolve(path) else { return nil }
        return nodes.map { SecretJSONDocument(source: source, node: $0) }
    }

    private func resolve(_ path: [JSONPathComponent]) -> Node? {
        var current = node
        for component in path {
            switch (component, current) {
            case (.key(let key), .object(let members)):
                guard let next = members[key] else { return nil }
                current = next
            case (.index(let index), .array(let nodes)):
                guard nodes.indices.contains(index) else { return nil }
                current = nodes[index]
            default:
                return nil
            }
        }
        return current
    }
}

/// A recursive-descent JSON validator over raw bytes (RFC 8259) that records value positions.
private struct JSONParser {

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let trueLiteral = Array("true".utf8)
    private static let falseLiteral = Array("false".utf8)
    private static let nullLiteral = Array("null".utf8)
    private static let hexDigitCount = 4
    /// `\uXXXX`: the backslash, the `u` and four hex digits.
    private static let unicodeEscapeLength = 6
    private static let highSurrogates: ClosedRange<UInt32> = 0xD800...0xDBFF
    private static let lowSurrogates: ClosedRange<UInt32> = 0xDC00...0xDFFF
    private static let supplementaryBase: UInt32 = 0x10000
    private static let surrogateShift: UInt32 = 10
    private static let decimalRadix: Int64 = 10
    /// Value of the hex digit `a`/`A`.
    private static let hexLetterBase: UInt32 = 10
    /// Bits per hex digit.
    private static let hexDigitBits: UInt32 = 4

    let bytes: UnsafeRawBufferPointer
    private var index = 0
    private var depth = 0

    init(bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws(DestinationError) -> SecretJSONDocument.Node {
        if bytes.count >= Self.byteOrderMark.count, Array(bytes[0..<Self.byteOrderMark.count]) == Self.byteOrderMark {
            index = Self.byteOrderMark.count
        }
        skipWhitespace()
        let node = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw .decoding }
        return node
    }

    // MARK: - Values

    private mutating func parseValue() throws(DestinationError) -> SecretJSONDocument.Node {
        guard index < bytes.count else { throw .decoding }
        switch bytes[index] {
        case JSONByte.quote:
            let range = try parseString()
            return .string(start: range.start, end: range.end, hasEscapes: range.hasEscapes)
        case JSONByte.openBrace:
            return try parseObject()
        case JSONByte.openBracket:
            return try parseArray()
        case JSONByte.lowercaseT:
            try expectLiteral(Self.trueLiteral)
            return .bool(true)
        case JSONByte.lowercaseF:
            try expectLiteral(Self.falseLiteral)
            return .bool(false)
        case JSONByte.lowercaseN:
            try expectLiteral(Self.nullLiteral)
            return .null
        case JSONByte.minus, JSONByte.zero...JSONByte.nine:
            return try parseNumber()
        default:
            throw .decoding
        }
    }

    private mutating func parseObject() throws(DestinationError) -> SecretJSONDocument.Node {
        try enterContainer()
        defer { depth -= 1 }
        index += 1
        var members: [String: SecretJSONDocument.Node] = [:]
        skipWhitespace()
        if peek() == JSONByte.closeBrace {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard peek() == JSONByte.quote else { throw .decoding }
            let keyRange = try parseString()
            guard let key = Self.decodeString(bytes, start: keyRange.start, end: keyRange.end, hasEscapes: keyRange.hasEscapes),
                  members[key] == nil
            else { throw .decoding }
            skipWhitespace()
            guard peek() == JSONByte.colon else { throw .decoding }
            index += 1
            skipWhitespace()
            members[key] = try parseValue()
            skipWhitespace()
            switch peek() {
            case JSONByte.comma:
                index += 1
            case JSONByte.closeBrace:
                index += 1
                return .object(members)
            default:
                throw .decoding
            }
        }
    }

    private mutating func parseArray() throws(DestinationError) -> SecretJSONDocument.Node {
        try enterContainer()
        defer { depth -= 1 }
        index += 1
        var elements: [SecretJSONDocument.Node] = []
        skipWhitespace()
        if peek() == JSONByte.closeBracket {
            index += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try parseValue())
            skipWhitespace()
            switch peek() {
            case JSONByte.comma:
                index += 1
            case JSONByte.closeBracket:
                index += 1
                return .array(elements)
            default:
                throw .decoding
            }
        }
    }

    /// Validates a string starting at the opening quote; returns the range between the quotes.
    private mutating func parseString() throws(DestinationError) -> (start: Int, end: Int, hasEscapes: Bool) {
        index += 1
        let start = index
        var hasEscapes = false
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case JSONByte.quote:
                let end = index
                index += 1
                return (start, end, hasEscapes)
            case JSONByte.backslash:
                hasEscapes = true
                try skipEscape()
            case ..<JSONByte.firstPrintable:
                throw .decoding
            default:
                guard let length = UTF8Validation.sequenceLength(in: bytes, at: index) else { throw .decoding }
                index += length
            }
        }
        throw .decoding
    }

    /// Validates one escape at the backslash, including a surrogate pair's second half.
    private mutating func skipEscape() throws(DestinationError) {
        guard index + 1 < bytes.count else { throw .decoding }
        switch bytes[index + 1] {
        case JSONByte.quote, JSONByte.backslash, JSONByte.slash, JSONByte.lowercaseB, JSONByte.lowercaseF, JSONByte.lowercaseN,
             JSONByte.lowercaseR, JSONByte.lowercaseT:
            index += 2
        case JSONByte.lowercaseU:
            guard let unit = Self.unicodeEscape(bytes, at: index) else { throw .decoding }
            index += Self.unicodeEscapeLength
            if Self.lowSurrogates.contains(unit) { throw .decoding }
            if Self.highSurrogates.contains(unit) {
                guard let low = Self.unicodeEscape(bytes, at: index), Self.lowSurrogates.contains(low) else {
                    throw .decoding
                }
                index += Self.unicodeEscapeLength
            }
        default:
            throw .decoding
        }
    }

    /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
    private mutating func parseNumber() throws(DestinationError) -> SecretJSONDocument.Node {
        let start = index
        if peek() == JSONByte.minus { index += 1 }
        guard let first = peek(), Self.isDigit(first) else { throw .decoding }
        if first == JSONByte.zero {
            index += 1
        } else {
            skipDigits()
        }
        if peek() == JSONByte.dot {
            index += 1
            guard let digit = peek(), Self.isDigit(digit) else { throw .decoding }
            skipDigits()
        }
        if peek() == JSONByte.lowercaseE || peek() == JSONByte.uppercaseE {
            index += 1
            if peek() == JSONByte.plus || peek() == JSONByte.minus { index += 1 }
            guard let digit = peek(), Self.isDigit(digit) else { throw .decoding }
            skipDigits()
        }
        return .number(start: start, end: index)
    }

    // MARK: - Helpers

    private mutating func enterContainer() throws(DestinationError) {
        depth += 1
        guard depth <= SecretJSONDocument.maxDepth else { throw .decoding }
    }

    private mutating func expectLiteral(_ literal: [UInt8]) throws(DestinationError) {
        guard index + literal.count <= bytes.count, Array(bytes[index..<(index + literal.count)]) == literal else {
            throw .decoding
        }
        index += literal.count
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == JSONByte.space || byte == JSONByte.tab || byte == JSONByte.lineFeed || byte == JSONByte.carriageReturn {
            index += 1
        }
    }

    private mutating func skipDigits() {
        while let byte = peek(), Self.isDigit(byte) {
            index += 1
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (JSONByte.zero...JSONByte.nine).contains(byte)
    }

    /// The code unit of `\uXXXX` at `position` (the backslash), or nil.
    private static func unicodeEscape(_ bytes: UnsafeRawBufferPointer, at position: Int) -> UInt32? {
        guard position + unicodeEscapeLength <= bytes.count,
              bytes[position] == JSONByte.backslash, bytes[position + 1] == JSONByte.lowercaseU
        else { return nil }
        var value: UInt32 = 0
        for offset in 2..<(2 + hexDigitCount) {
            guard let digit = hexValue(bytes[position + offset]) else { return nil }
            value = value << hexDigitBits | digit
        }
        return value
    }

    private static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case JSONByte.zero...JSONByte.nine: UInt32(byte - JSONByte.zero)
        case JSONByte.uppercaseA...JSONByte.uppercaseF: UInt32(byte - JSONByte.uppercaseA) + hexLetterBase
        case JSONByte.lowercaseA...JSONByte.lowercaseF: UInt32(byte - JSONByte.lowercaseA) + hexLetterBase
        default: nil
        }
    }

    // MARK: - Decoding (after validation)

    /// Writes the unescaped bytes of a validated string into `buffer`. False on anything
    /// unexpected (never for a range the parser accepted).
    static func unescape(
        _ bytes: UnsafeRawBufferPointer,
        start: Int,
        end: Int,
        hasEscapes: Bool,
        into buffer: SecretByteBuffer
    ) -> Bool {
        guard start >= 0, start <= end, end <= bytes.count else { return false }
        guard hasEscapes else {
            buffer.append(UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
            return true
        }
        var position = start
        while position < end {
            let byte = bytes[position]
            guard byte == JSONByte.backslash else {
                buffer.append(byte)
                position += 1
                continue
            }
            guard position + 1 < end else { return false }
            let escaped = bytes[position + 1]
            switch escaped {
            case JSONByte.quote, JSONByte.backslash, JSONByte.slash:
                buffer.append(escaped)
                position += 2
            case JSONByte.lowercaseB: buffer.append(JSONByte.backspace); position += 2
            case JSONByte.lowercaseF: buffer.append(JSONByte.formFeed); position += 2
            case JSONByte.lowercaseN: buffer.append(JSONByte.lineFeed); position += 2
            case JSONByte.lowercaseR: buffer.append(JSONByte.carriageReturn); position += 2
            case JSONByte.lowercaseT: buffer.append(JSONByte.tab); position += 2
            case JSONByte.lowercaseU:
                guard let unit = unicodeEscape(bytes, at: position) else { return false }
                position += unicodeEscapeLength
                var scalarValue = unit
                if highSurrogates.contains(unit) {
                    guard let low = unicodeEscape(bytes, at: position), lowSurrogates.contains(low) else { return false }
                    position += unicodeEscapeLength
                    scalarValue = supplementaryBase
                        + ((unit - highSurrogates.lowerBound) << surrogateShift)
                        + (low - lowSurrogates.lowerBound)
                } else if lowSurrogates.contains(unit) {
                    return false
                }
                guard let scalar = Unicode.Scalar(scalarValue), let encoded = UTF8.encode(scalar) else { return false }
                for unit in encoded {
                    buffer.append(unit)
                }
            default:
                return false
            }
        }
        return true
    }

    /// A validated string as a `String` (value-free fields and keys only).
    static func decodeString(_ bytes: UnsafeRawBufferPointer, start: Int, end: Int, hasEscapes: Bool) -> String? {
        let buffer = SecretByteBuffer(capacity: end - start)
        defer { buffer.wipe() }
        guard unescape(bytes, start: start, end: end, hasEscapes: hasEscapes, into: buffer) else { return nil }
        return buffer.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
    }

    /// A validated number as `Int64` when it is integral and fits.
    static func integer(_ bytes: UnsafeRawBufferPointer, start: Int, end: Int) -> Int64? {
        guard start >= 0, start < end, end <= bytes.count else { return nil }
        let slice = UnsafeRawBufferPointer(rebasing: bytes[start..<end])
        let isPlainInteger = slice.allSatisfy { isDigit($0) || $0 == JSONByte.minus }
        if isPlainInteger {
            let isNegative = slice.first == JSONByte.minus
            var value: Int64 = 0
            for byte in slice where byte != JSONByte.minus {
                let digit = Int64(byte - JSONByte.zero)
                let (shifted, shiftOverflow) = value.multipliedReportingOverflow(by: decimalRadix)
                let (next, addOverflow) = isNegative
                    ? shifted.subtractingReportingOverflow(digit)
                    : shifted.addingReportingOverflow(digit)
                guard !shiftOverflow, !addOverflow else { return nil }
                value = next
            }
            return value
        }
        guard let number = Double(String(decoding: slice, as: UTF8.self)), number.isFinite,
              number.rounded() == number
        else { return nil }
        return Int64(exactly: number)
    }
}
