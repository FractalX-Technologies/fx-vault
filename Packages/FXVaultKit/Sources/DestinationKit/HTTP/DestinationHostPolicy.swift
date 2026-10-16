import Foundation
import GitHubKit
import VaultCore

/// The only places FX Vault sends HTTP requests to (v0.8.0, tasks/todo.md R4).
///
/// A URL is allowed when it is `https`, has no user or password, uses the default port (or an
/// explicit 443, as Key Vault's `nextLink` does), and its host is exactly `api.supabase.com`,
/// `api.vercel.com`, or `<vault>.vault.azure.net` where `<vault>` passes
/// `DestinationRules.isValidKeyVaultName`. Hosts are compared case-insensitively; a trailing dot,
/// another subdomain or an IP address is refused.
enum DestinationHostPolicy {
    /// True when a request may go to `url`.
    static func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == DestinationConstants.httpsScheme,
              components.user == nil, components.password == nil,
              components.port == nil || components.port == DestinationConstants.httpsPort,
              let host = components.host
        else { return false }
        return isAllowedHost(host)
    }

    /// True when `host` is one of the allowlisted hosts.
    static func isAllowedHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == DestinationConstants.supabaseHost || host == DestinationConstants.vercelHost {
            return true
        }
        guard host.hasSuffix(DestinationConstants.keyVaultHostSuffix) else { return false }
        let vaultName = String(host.dropLast(DestinationConstants.keyVaultHostSuffix.count))
        return DestinationRules.isValidKeyVaultName(vaultName)
    }

    /// True when `url` is allowed and on the same host as `origin` (Key Vault `nextLink`).
    static func isSameAllowedHost(_ url: URL, as origin: URL) -> Bool {
        guard isAllowed(url), let host = url.host?.lowercased(), let originHost = origin.host?.lowercased() else {
            return false
        }
        return host == originHost
    }

    /// `<vault>.vault.azure.net`, lowercased.
    static func keyVaultHost(vaultName: String) -> String {
        vaultName.lowercased() + DestinationConstants.keyVaultHostSuffix
    }
}

/// Builds provider URLs from validated, percent-encoded parts, so a name can never change a
/// request's shape (same rules as GitHubKit's `GitHubPath`, D29).
enum ProviderURL {
    /// `https://<host>/<segments>?<query>`.
    ///
    /// Every segment must pass `PathSegmentValidator` (no `.`/`..`, separators or control
    /// characters, also percent-encoded) and is encoded with the RFC 3986 unreserved set;
    /// query keys and values are encoded the same way. Throws
    /// ``DestinationError/invalidInput(_:)`` for a bad segment and
    /// ``DestinationError/disallowedHost`` when the host is not allowlisted.
    static func make(
        host: String,
        segments: [String],
        query: [(name: String, value: String)] = []
    ) throws(DestinationError) -> URL {
        var path = ""
        for segment in segments {
            do {
                try PathSegmentValidator.validate(segment)
            } catch {
                throw .invalidInput(error)
            }
            path += "/" + GitHubPath.percentEncode(segment)
        }
        var text = "\(DestinationConstants.httpsScheme)://\(host)\(path)"
        if !query.isEmpty {
            text += "?" + query.map { "\(GitHubPath.percentEncode($0.name))=\(GitHubPath.percentEncode($0.value))" }
                .joined(separator: "&")
        }
        guard let url = URL(string: text), DestinationHostPolicy.isAllowed(url) else {
            throw .disallowedHost
        }
        return url
    }
}
