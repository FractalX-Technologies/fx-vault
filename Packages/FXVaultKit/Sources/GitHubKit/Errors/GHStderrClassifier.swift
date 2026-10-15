import Foundation
import VaultCore

/// Everything the classifier knows about a failed gh call (tasks/todo.md §8 E).
public struct GHFailureContext: Sendable, Hashable {
    public var operation: GHOperation
    public var exitCode: Int32
    /// Redacted stderr (run ``StderrRedactor`` first).
    public var stderr: String
    /// The status line of a `gh api -i` response, when there was one.
    public var responseStatus: Int?
    /// True when the runner terminated the process after its timeout.
    public var didTimeOut: Bool
    /// The `errors[]` details of a failed `gh api -i` response body
    /// (``APIResponseParser/errorDetails(in:)``), token patterns redacted. gh never prints
    /// them on stderr.
    public var responseDetails: [String]

    public init(
        operation: GHOperation,
        exitCode: Int32,
        stderr: String,
        responseStatus: Int? = nil,
        didTimeOut: Bool = false,
        responseDetails: [String] = []
    ) {
        self.operation = operation
        self.exitCode = exitCode
        self.stderr = stderr
        self.responseStatus = responseStatus
        self.didTimeOut = didTimeOut
        self.responseDetails = responseDetails
    }
}

/// Maps a failed gh call to a ``GHError`` with the ordered rules of tasks/todo.md §8 E.
///
/// Rules match on status codes and short, lowercase fragments, never on whole sentences.
/// gh's wording is not a stable interface: the fixtures in `Tests/GitHubKitTests/Fixtures/gh`
/// are re-recorded whenever the gh floor moves, and the M3 write spike re-checks the fragments.
///
/// Status sources, in order: the `-i` status line; native `HTTP nnn: ` anywhere in stderr
/// (gh wraps it, for example `failed to delete secret X: HTTP 404: Not Found (...)`); the
/// `gh api` line forms `gh: <message> (HTTP nnn)` and `gh: HTTP nnn`.
public enum GHStderrClassifier {
    /// gh exit codes (`gh help exit-codes`).
    public enum ExitCode {
        public static let success: Int32 = 0
        public static let error: Int32 = 1
        public static let cancelled: Int32 = 2
        public static let authenticationRequired: Int32 = 4
    }

    /// HTTP statuses the rules use.
    enum HTTPStatus {
        static let unauthorized = 401
        static let notFound = 404
        static let unprocessable = 422
        static let tooManyRequests = 429
        static let serverErrors: Set<Int> = [500, 502, 503, 504]
        static let digitCount = 3
    }

    static let networkFragments = [
        "dial tcp", "no such host", "connection refused", "connection reset", "i/o timeout",
        "tls handshake timeout", "error connecting to ", "check your internet connection",
    ]
    static let rateLimitFragments = ["secondary rate limit", "api rate limit exceeded"]
    static let writeAccessFragments = ["resource not accessible", "repository read permissions"]
    static let missingScopeFragments = [
        "missing required scopes", "has not been granted the required scopes",
    ]
    static let orgPolicyFragments = [
        "organization policy", "repository creation is restricted", "restricted repository creation",
        "cannot create repositories", "not allowed to create repositor", "policy prohibits",
    ]
    static let planFragments = [
        "billing plan", "upgrade to github pro", "make this repository public to enable this feature",
    ]
    static let notFoundFragments = ["not found", "could not resolve to a repository"]
    static let badCredentialsFragment = "bad credentials"
    static let notLoggedInFragment = "you are not logged into any github hosts"
    static let samlFragment = "saml"
    static let adminFragment = "must have admin rights"
    static let alreadyExistsFragment = "already exists"
    static let ownerLookupFragment = "/users/"
    static let authorizePrefix = "Authorize in your web browser:"
    static let ssoLinkPrefix = "https://github.com/orgs/"
    static let ssoPathFragment = "/sso"
    static let needsScopePrefix = "needs the \""
    static let missingScopesPrefix = "missing required scopes ["

    /// Classifies a failure with the §8 E rules, in priority order.
    ///
    /// A `gh api` failure whose stderr alone reads as `.validation` or `.unexpected` is checked
    /// again with the response body's `errors[]` details appended: a plan, permission, SAML,
    /// scope or rate-limit reason found only there wins. Any other class from the details is
    /// ignored (a 422 whose detail says "not found" stays a validation error).
    public static func classify(_ context: GHFailureContext) -> GHError {
        let base = classify(context, text: context.stderr)
        guard !context.responseDetails.isEmpty else { return base }
        switch base {
        case .validation, .unexpected: break
        default: return base
        }
        let detailed = classify(context, text: context.stderr + "\n" + context.responseDetails.joined(separator: "\n"))
        switch detailed {
        case .planGated, .adminRequired, .writeAccessRequired, .missingScopes, .samlRequired, .rateLimited,
             .orgPolicyForbidsCreate:
            return detailed
        default:
            return base
        }
    }

    private static func classify(_ context: GHFailureContext, text: String) -> GHError {
        let lower = text.lowercased()
        let status = context.responseStatus ?? nativeStatus(in: text) ?? apiStatus(in: text)

        // 1. Checked first: a native 401 also prints "Try authenticating with: gh auth login".
        if status == HTTPStatus.unauthorized || lower.contains(badCredentialsFragment) {
            return .tokenRevoked
        }
        // 2. Never on the bare fragment "gh auth login".
        if context.exitCode == ExitCode.authenticationRequired || lower.contains(notLoggedInFragment) {
            return .notAuthenticated
        }
        // 3.
        if lower.contains(samlFragment) {
            return .samlRequired(samlURL(in: text))
        }
        // 4.
        if status == HTTPStatus.tooManyRequests || containsAny(lower, rateLimitFragments) {
            return .rateLimited
        }
        // 5.
        if lower.contains(adminFragment) {
            return .adminRequired
        }
        // 6.
        if containsAny(lower, writeAccessFragments) {
            return .writeAccessRequired
        }
        let neededScopes = scopes(in: text)
        if !neededScopes.isEmpty || containsAny(lower, missingScopeFragments) {
            return .missingScopes(neededScopes)
        }
        // 7.
        if context.operation == .repoCreate, containsAny(lower, orgPolicyFragments) {
            return .orgPolicyForbidsCreate
        }
        // 8.
        if containsAny(lower, planFragments) {
            return .planGated
        }
        // 9. `gh repo create OWNER/NAME` first looks up `users/<owner>`: a 404 there means the
        // owner is invalid, not a missing repository (§8 C1).
        if status == HTTPStatus.notFound || containsAny(lower, notFoundFragments) {
            if context.operation == .repoCreate, lower.contains(ownerLookupFragment) {
                return .validation(message(from: text))
            }
            return .notFound
        }
        // 10.
        if status == HTTPStatus.unprocessable || lower.contains(alreadyExistsFragment) {
            return .validation(message(from: text))
        }
        // 11.
        if let status, HTTPStatus.serverErrors.contains(status) {
            return .serverError(status: status)
        }
        // 12.
        if containsAny(lower, networkFragments) {
            return .network
        }
        // 13.
        if context.didTimeOut {
            return context.operation.isWrite ? .indeterminate : .timeout
        }
        // 14.
        return .unexpected(exitCode: context.exitCode)
    }

    /// True when `text` contains one of the network fragments of rule 12 (also used for the
    /// `error` field of `gh auth status --json hosts`, §8 A3).
    public static func isNetworkFailure(_ text: String) -> Bool {
        containsAny(text.lowercased(), networkFragments)
    }

    /// True when `text` reports an invalid token (rule 1).
    public static func isBadCredentials(_ text: String) -> Bool {
        nativeStatus(in: text) == HTTPStatus.unauthorized
            || text.lowercased().contains(badCredentialsFragment)
            || text.contains("HTTP \(HTTPStatus.unauthorized)")
    }

    // MARK: - Status extraction

    /// The first `HTTP nnn: ` anywhere in `text` (native commands).
    static func nativeStatus(in text: String) -> Int? {
        let marker = "HTTP "
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: marker, range: searchRange) {
            if let status = threeDigits(in: text, from: range.upperBound, followedBy: ":") {
                return status
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return nil
    }

    /// `gh: <message> (HTTP nnn)` or `gh: HTTP nnn` on a line of its own (`gh api`).
    static func apiStatus(in text: String) -> Int? {
        let prefix = "gh: "
        let bareMarker = "HTTP "
        let wrappedMarker = " (HTTP "
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { continue }
            let rest = line.dropFirst(prefix.count)
            if rest.hasPrefix(bareMarker) {
                let digits = rest.dropFirst(bareMarker.count)
                if digits.count == HTTPStatus.digitCount, let status = Int(digits) {
                    return status
                }
            }
            if line.hasSuffix(")"), let range = line.range(of: wrappedMarker, options: .backwards) {
                let digits = line[range.upperBound...].dropLast()
                if digits.count == HTTPStatus.digitCount, let status = Int(digits) {
                    return status
                }
            }
        }
        return nil
    }

    private static func threeDigits(in text: String, from start: String.Index, followedBy terminator: Character)
        -> Int?
    {
        guard let end = text.index(start, offsetBy: HTTPStatus.digitCount, limitedBy: text.endIndex),
              end < text.endIndex, text[end] == terminator
        else { return nil }
        let digits = text[start..<end]
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    // MARK: - Details

    /// The SAML authorization URL: `Authorize in your web browser:` followed by one space
    /// (`gh api`) or two (native), else a `https://github.com/orgs/<org>/sso` link. Only
    /// `https://github.com/...` URLs are returned.
    static func samlURL(in text: String) -> URL? {
        if let range = text.range(of: authorizePrefix) {
            let token = text[range.upperBound...]
                .drop(while: { $0 == " " || $0 == "\t" })
                .prefix(while: { !$0.isWhitespace })
            if let url = gitHubURL(String(token)) {
                return url
            }
        }
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: ssoLinkPrefix, range: searchRange) {
            let token = text[range.lowerBound...].prefix(while: { !$0.isWhitespace })
            if token.contains(ssoPathFragment), let url = gitHubURL(String(token)) {
                return url
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return nil
    }

    private static func gitHubURL(_ candidate: String) -> URL? {
        let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ").,;'\""))
        guard let url = URL(string: trimmed),
              url.scheme == "https",
              url.host?.lowercased() == GHConstants.host
        else { return nil }
        return url
    }

    /// Scopes named by `needs the "x" scope` or `missing required scopes [a b]`.
    static func scopes(in text: String) -> [String] {
        var found: [String] = []
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: needsScopePrefix, range: searchRange) {
            let scope = text[range.upperBound...].prefix(while: { $0 != "\"" })
            if !scope.isEmpty, !found.contains(String(scope)) {
                found.append(String(scope))
            }
            searchRange = range.upperBound..<text.endIndex
        }
        if let range = text.range(of: missingScopesPrefix, options: .caseInsensitive) {
            let list = text[range.upperBound...].prefix(while: { $0 != "]" })
            let separators = CharacterSet(charactersIn: ", ")
            for scope in list.components(separatedBy: separators) where !scope.isEmpty {
                if !found.contains(scope) {
                    found.append(scope)
                }
            }
        }
        return found
    }

    /// The first non-empty stderr line, followed by the response body's details when there are
    /// any (`gh: Validation Failed (HTTP 422): <detail>; <detail>`), trimmed and capped. Both
    /// must already be redacted.
    static func message(from text: String, details: [String] = []) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let message = details.isEmpty ? line : line + detailSeparator + details.joined(separator: detailJoiner)
        return String(message.prefix(GHConstants.maxErrorMessageLength))
    }

    private static let detailSeparator = ": "
    private static let detailJoiner = "; "

    private static func containsAny(_ text: String, _ fragments: [String]) -> Bool {
        fragments.contains { text.contains($0) }
    }
}
