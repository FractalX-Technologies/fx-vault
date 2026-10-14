import Foundation
import VaultCore

/// Decodes gh's `--json` and `gh api` output (tasks/todo.md §8 conventions).
///
/// - Unknown fields are ignored (Codable's default); missing required fields fail decoding.
/// - Dates are RFC 3339 / ISO 8601, with or without fractional seconds (gh marshals Go
///   `time.Time`, GitHub's REST API sends whole seconds).
/// - The temporary `Data` copy of the output is wiped after decoding. The `SecretBytes` the
///   caller passed in is not wiped here; ``GHCommandOutput`` decoders wipe it.
enum GHJSONDecoding {
    /// Decodes `type` from `bytes`, or throws ``GHError/malformedOutput``.
    static func decode<T: Decodable>(_ type: T.Type, from bytes: SecretBytes) throws(GHError) -> T {
        var data = bytes.withUnsafeBytes { Data($0) }
        defer { data.secureWipe() }
        return try decode(type, from: data)
    }

    /// Decodes `type` from `data`, or throws ``GHError/malformedOutput``.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws(GHError) -> T {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw .malformedOutput
        }
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Not an ISO 8601 date"
                )
            }
            return date
        }
        return decoder
    }

    /// Parses an ISO 8601 / RFC 3339 timestamp with or without fractional seconds.
    static func parseDate(_ text: String) -> Date? {
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        if let date = whole.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
