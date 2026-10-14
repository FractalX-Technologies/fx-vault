import Foundation
import VaultCore

/// A REST path for `gh api`, built from validated, percent-encoded segments
/// (tasks/todo.md §8 conventions, D29).
///
/// Each dynamic segment must pass `PathSegmentValidator` (no empty strings, no `.`/`..` or
/// encoded forms, no separators, no control/bidi/zero-width characters) and is then encoded
/// with the RFC 3986 unreserved set, so `/`, `?`, `#`, `%` and spaces can never change the
/// request's shape. Only `environments` and branch-policy paths are built (D4).
public struct GitHubPath: Sendable, Hashable, CustomStringConvertible {
    /// The encoded path, without a leading slash, with the query string if any.
    public let rendered: String

    /// Characters that stay as they are: `A–Z a–z 0–9 - . _ ~` (RFC 3986 unreserved).
    static let unreservedCharacters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    private static let reposSegment = "repos"
    private static let environmentsSegment = "environments"
    private static let branchPoliciesSegment = "deployment-branch-policies"
    private static let perPageKey = "per_page"

    /// Validates and encodes `segments`. Literal segments are validated too.
    init(segments: [String], query: [(key: String, value: String)] = []) throws(GHError) {
        var encoded: [String] = []
        for segment in segments {
            encoded.append(try Self.encodeValidated(segment))
        }
        var rendered = encoded.joined(separator: "/")
        if !query.isEmpty {
            let pairs = query.map { "\(Self.percentEncode($0.key))=\(Self.percentEncode($0.value))" }
            rendered += "?" + pairs.joined(separator: "&")
        }
        self.rendered = rendered
    }

    public var description: String {
        rendered
    }

    /// Percent-encodes one segment with the unreserved set (UTF-8, uppercase hex). Does not
    /// validate: `a/b c` → `a%2Fb%20c`.
    public static func percentEncode(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? ""
    }

    /// Validates `segment` with `PathSegmentValidator`, encodes it, and re-checks the result
    /// (non-empty, not a dot segment, decodes back to the input).
    public static func encodeValidated(_ segment: String) throws(GHError) -> String {
        do {
            try PathSegmentValidator.validate(segment)
        } catch {
            throw .invalidInput(error)
        }
        let encoded = percentEncode(segment)
        guard !encoded.isEmpty,
              encoded != ".", encoded != "..",
              encoded.removingPercentEncoding == segment
        else { throw .invalidInput(.invalidPathSegment(.encodedDotSegment)) }
        return encoded
    }

    // MARK: - The paths FX Vault uses (§8 B3–B5, C2–C4, C9)

    /// `repos/{o}/{r}/environments?per_page=100`
    static func environments(_ repo: GHRepoRef) throws(GHError) -> GitHubPath {
        try GitHubPath(
            segments: [reposSegment, repo.owner, repo.name, environmentsSegment],
            query: [(perPageKey, String(GHConstants.apiPerPage))]
        )
    }

    /// `repos/{o}/{r}/environments/{e}`
    static func environment(_ repo: GHRepoRef, name: String) throws(GHError) -> GitHubPath {
        try GitHubPath(segments: [reposSegment, repo.owner, repo.name, environmentsSegment, name])
    }

    /// `repos/{o}/{r}/environments/{e}/deployment-branch-policies[?per_page=100]`
    static func branchPolicies(_ repo: GHRepoRef, environment: String, paginated: Bool) throws(GHError)
        -> GitHubPath
    {
        try GitHubPath(
            segments: [reposSegment, repo.owner, repo.name, environmentsSegment, environment, branchPoliciesSegment],
            query: paginated ? [(perPageKey, String(GHConstants.apiPerPage))] : []
        )
    }

    /// `repos/{o}/{r}/environments/{e}/deployment-branch-policies/{id}`
    static func branchPolicy(_ repo: GHRepoRef, environment: String, policyID: Int64) throws(GHError)
        -> GitHubPath
    {
        try GitHubPath(segments: [
            reposSegment, repo.owner, repo.name, environmentsSegment, environment, branchPoliciesSegment,
            String(policyID),
        ])
    }
}
