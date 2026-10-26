import Foundation

/// Generate in Set value… (board Place-SecretValue): 32 random bytes as base64url without padding,
/// 43 characters a shell, a URL or a `.env` line takes as they are.
enum NotesValueGenerator {
    static let byteCount = 32

    static func value() -> String {
        var generator = SystemRandomNumberGenerator()
        return value(using: &generator)
    }

    static func value(using generator: inout some RandomNumberGenerator) -> String {
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
