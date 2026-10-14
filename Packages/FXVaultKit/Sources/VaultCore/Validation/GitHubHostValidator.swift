/// The only GitHub host FX Vault talks to (D29, §9.3).
public enum GitHubHostValidator {
    /// `github.com`. GitHub Enterprise hosts are out of scope.
    public static let host = "github.com"

    /// Returns `host` when it is exactly ``host`` (case-sensitive, no port, no trailing dot).
    @discardableResult
    public static func validate(_ host: String) throws(ValidationError) -> String {
        guard isValid(host) else { throw .invalidHost }
        return host
    }

    /// True when `host` is exactly ``host``.
    public static func isValid(_ host: String) -> Bool {
        host == Self.host
    }
}
