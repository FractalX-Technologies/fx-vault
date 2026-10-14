import Foundation
import VaultCore

/// Crockford Base32 (§5.3): alphabet `0-9 A-Z` without `I L O U`, most significant bit first,
/// the last character padded with zero bits.
///
/// Decoding is forgiving the way Crockford specifies, so typed keys work: case-insensitive,
/// `I`/`L` read as `1`, `O` as `0`, and `-` and whitespace are ignored. `U` and every other
/// character are rejected.
public enum CrockfordBase32 {
    /// The 32 encoding symbols in value order.
    public static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    /// Encodes `bytes`. `ceil(8 × count / 5)` characters.
    public static func encode(_ bytes: some Sequence<UInt8>) -> String {
        var output: [UInt8] = []
        var buffer: UInt32 = 0
        var bitCount = 0
        for byte in bytes {
            buffer = (buffer << bitsPerByte) | UInt32(byte)
            bitCount += bitsPerByte
            while bitCount >= bitsPerSymbol {
                bitCount -= bitsPerSymbol
                output.append(symbols[Int((buffer >> UInt32(bitCount)) & symbolMask)])
            }
            buffer &= (1 << UInt32(bitCount)) - 1
        }
        if bitCount > 0 {
            output.append(symbols[Int((buffer << UInt32(bitsPerSymbol - bitCount)) & symbolMask)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Encodes the contents of `secret` (for display only; the `String` cannot be wiped).
    public static func encode(_ secret: SecretBytes) -> String {
        secret.withUnsafeBytes { encode($0) }
    }

    /// The canonical form of user input: uppercase symbols only, separators removed, `I`/`L`
    /// mapped to `1` and `O` to `0`. Nil if any other character (including `U`) appears.
    public static func normalize(_ text: String) -> String? {
        var output: [UInt8] = []
        output.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            if scalar == separator || scalar.properties.isWhitespace { continue }
            guard scalar.isASCII, let symbol = canonicalSymbol(UInt8(scalar.value)) else { return nil }
            output.append(symbol)
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Decodes `text` (normalized first) into a wipeable buffer.
    ///
    /// Returns nil for an invalid character, a length no encoding produces, or non-zero padding
    /// bits, so every byte string has exactly one accepted canonical spelling.
    public static func decode(_ text: String) -> SecretBytes? {
        guard let normalized = normalize(text) else { return nil }
        let characters = Array(normalized.utf8)
        let byteCount = characters.count * bitsPerSymbol / bitsPerByte
        guard encodedLength(byteCount: byteCount) == characters.count else { return nil }

        let output = SecretBytes(count: byteCount)
        let isValid = output.withUnsafeMutableBytes { out in
            var buffer: UInt32 = 0
            var bitCount = 0
            var index = 0
            for character in characters {
                guard let value = values[Int(character)] else { return false }
                buffer = (buffer << UInt32(bitsPerSymbol)) | UInt32(value)
                bitCount += bitsPerSymbol
                if bitCount >= bitsPerByte {
                    bitCount -= bitsPerByte
                    out[index] = UInt8(truncatingIfNeeded: buffer >> UInt32(bitCount))
                    index += 1
                }
                buffer &= (1 << UInt32(bitCount)) - 1
            }
            // The bits left in `buffer` are padding and must be zero.
            let padding = buffer
            buffer = 0
            return index == byteCount && padding == 0
        }
        guard isValid else {
            output.wipe()
            return nil
        }
        return output
    }

    /// Characters needed for `byteCount` bytes.
    public static func encodedLength(byteCount: Int) -> Int {
        (byteCount * bitsPerByte + bitsPerSymbol - 1) / bitsPerSymbol
    }

    // MARK: - Private

    private static let bitsPerByte = 8
    private static let bitsPerSymbol = 5
    private static let symbolMask: UInt32 = 0b1_1111
    private static let separator: Unicode.Scalar = "-"
    private static let symbols = Array(alphabet.utf8)

    /// Value of each canonical ASCII symbol, indexed by byte.
    private static let values: [UInt8?] = {
        var table = [UInt8?](repeating: nil, count: Int(UInt8.max) + 1)
        for (value, symbol) in symbols.enumerated() {
            table[Int(symbol)] = UInt8(value)
        }
        return table
    }()

    /// Maps an ASCII byte to its canonical uppercase symbol, or nil if it is not accepted.
    private static func canonicalSymbol(_ byte: UInt8) -> UInt8? {
        let upper = (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) ? byte - asciiCaseOffset : byte
        switch upper {
        case UInt8(ascii: "I"), UInt8(ascii: "L"): return UInt8(ascii: "1")
        case UInt8(ascii: "O"): return UInt8(ascii: "0")
        default: return values[Int(upper)] == nil ? nil : upper
        }
    }

    private static let asciiCaseOffset = UInt8(ascii: "a") - UInt8(ascii: "A")
}
