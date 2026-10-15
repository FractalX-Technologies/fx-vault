import Foundation
import VaultCore

/// A `gh api -i` response: status line, headers and body (tasks/todo.md §8 conventions).
public struct APIResponseModel: Sendable, Hashable {
    /// The HTTP status of the final response (gh follows redirects; `-i` shows only the last).
    public let status: Int
    /// Header names lowercased. Only ``APIResponseParser/keptHeaders`` are kept.
    public let headers: [String: String]
    /// The body (may be empty, for example on 204).
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// True for 2xx.
    public var isSuccess: Bool {
        APIResponseParser.successStatuses.contains(status)
    }
}

/// Parses `gh api -i` stdout and `gh api --paginate --slurp` output.
public enum APIResponseParser {
    static let successStatuses = 200..<300
    /// Headers worth keeping; everything else (request ids, rate-limit counters, cookies) is
    /// dropped on parse.
    public static let keptHeaders: Set<String> = ["content-type", "location"]
    private static let httpPrefix = "HTTP/"
    private static let crlfcrlf = Data("\r\n\r\n".utf8)
    private static let lflf = Data("\n\n".utf8)
    private static let statusDigitCount = 3
    private static let errorsKey = "errors"
    private static let messageKey = "message"
    private static let detailFieldKeys = ["resource", "field", "code"]

    /// Parses the head (status line and headers) and the body. Accepts `\r\n` or `\n` line
    /// endings (gh writes the status line with `\n` and headers with `\r\n`).
    public static func parse(_ output: Data) throws(GHError) -> APIResponseModel {
        let separator = headSeparator(in: output)
        let headData = separator.map { output[output.startIndex..<$0.lowerBound] } ?? output[...]
        let body = separator.map { Data(output[$0.upperBound...]) } ?? Data()
        guard let head = String(data: Data(headData), encoding: .utf8) else { throw .malformedOutput }
        let lines = head.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        guard let statusLine = lines.first, let status = statusCode(from: statusLine) else {
            throw .malformedOutput
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard keptHeaders.contains(name) else { continue }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return APIResponseModel(status: status, headers: headers, body: body)
    }

    /// The status in `HTTP/<version> <status> <reason>`, or nil.
    public static func statusCode(from line: String) -> Int? {
        guard line.hasPrefix(httpPrefix) else { return nil }
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[1].count == statusDigitCount else { return nil }
        return Int(parts[1])
    }

    /// The status line of `-i` output that might not be a complete response (for example a
    /// failed call), or nil.
    public static func statusIfPresent(in output: Data) -> Int? {
        guard let firstLineEnd = output.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = String(decoding: output[output.startIndex..<firstLineEnd], as: UTF8.self)
        return statusCode(from: line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
    }

    /// The `errors[]` entries of a failed `gh api -i` response body (§8 E).
    ///
    /// gh prints only the body's top-level `message` on stderr (`gh: Validation Failed (HTTP
    /// 422)`); the details GitHub puts in `errors` (strings, or objects with a `message`, or
    /// `resource`/`field`/`code`) reach stdout only. Returns at most
    /// `GHConstants.maxErrorDetailCount` entries, each capped at
    /// `GHConstants.maxErrorMessageLength`; empty when there is no parsable body.
    public static func errorDetails(in output: Data) -> [String] {
        guard let response = try? parse(output),
              !response.body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let errors = object[errorsKey] as? [Any]
        else { return [] }
        let details = errors.compactMap { entry -> String? in
            let text: String? = switch entry {
            case let text as String:
                text
            case let fields as [String: Any]:
                (fields[messageKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? detailFieldKeys.compactMap { fields[$0] as? String }.joined(separator: " ")
            default:
                nil
            }
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return String(text.prefix(GHConstants.maxErrorMessageLength))
        }
        return Array(details.prefix(GHConstants.maxErrorDetailCount))
    }

    /// Decodes `--paginate --slurp` output: a JSON array with one element per page.
    public static func decodePages<Page: Decodable>(_ type: Page.Type, from data: Data) throws(GHError) -> [Page] {
        try GHJSONDecoding.decode([Page].self, from: data)
    }

    private static func headSeparator(in data: Data) -> Range<Data.Index>? {
        let crlf = data.range(of: crlfcrlf)
        let lf = data.range(of: lflf)
        switch (crlf, lf) {
        case let (crlf?, lf?): return crlf.lowerBound <= lf.lowerBound ? crlf : lf
        case let (crlf?, nil): return crlf
        case let (nil, lf?): return lf
        case (nil, nil): return nil
        }
    }
}
