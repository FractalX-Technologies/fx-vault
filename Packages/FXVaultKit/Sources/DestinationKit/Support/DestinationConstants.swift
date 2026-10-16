import Foundation
import GitHubKit
import os

/// Fixed strings and protocol constants of the destination clients (v0.8.0, tasks/todo.md R4).
///
/// Numeric limits and durations shared with the rest of the app live in VaultCore's `Limits` and
/// `Timeouts`; this enum holds what only DestinationKit needs.
public enum DestinationConstants {
    /// `User-Agent` of every request.
    public static let userAgent = "FXVault"
    /// The Supabase Management API host.
    public static let supabaseHost = "api.supabase.com"
    /// The Vercel REST API host.
    public static let vercelHost = "api.vercel.com"
    /// A Key Vault host is `<vault name>` followed by this suffix.
    public static let keyVaultHostSuffix = ".vault.azure.net"
    /// The Key Vault data-plane API version.
    public static let keyVaultAPIVersion = "7.4"
    /// The resource `az account get-access-token` issues Key Vault tokens for.
    public static let keyVaultResource = "https://vault.azure.net"

    /// `maxresults` of a Key Vault list page (the service's maximum).
    static let keyVaultPageSize = 25
    /// `limit` of a Vercel list page (projects, teams).
    static let vercelPageSize = 100
    /// Most pages one listing follows before it stops with ``DestinationError/responseTooLarge``.
    /// Local choice (10,000 Key Vault secrets).
    static let maxListPages = 400
    /// Longest provider error code kept in an error (`[A-Za-z0-9_.-]`).
    static let maxErrorCodeLength = 64
    /// The only URL scheme FX Vault sends requests to.
    static let httpsScheme = "https"
    /// The only port FX Vault connects to (implicit in `https` URLs).
    static let httpsPort = 443
    /// `Content-Type` and `Accept` of every request with a JSON body or answer.
    static let jsonMediaType = "application/json"
}

/// HTTP header names DestinationKit sets or reads. Response header names are lowercased by
/// ``HTTPResponseModel``.
enum HTTPHeader {
    static let authorization = "Authorization"
    static let bearerPrefix = "Bearer "
    static let userAgent = "User-Agent"
    static let accept = "Accept"
    static let contentType = "Content-Type"
    static let retryAfter = "retry-after"
    /// Headers a caller can never set through ``HTTPRequestModel/headers``: the transport owns
    /// them (lowercased).
    static let reserved: Set<String> = ["authorization", "user-agent", "cookie", "host", "content-length"]
}

/// HTTP status codes the clients classify (RFC 9110).
enum HTTPStatus {
    static let success = 200..<300
    static let redirection = 300..<400
    static let clientError = 400..<500
    static let serverError = 500..<600
    static let badRequest = 400
    static let unauthorized = 401
    static let paymentRequired = 402
    static let forbidden = 403
    static let notFound = 404
    static let conflict = 409
    static let gone = 410
    static let payloadTooLarge = 413
    static let unprocessableContent = 422
    static let tooManyRequests = 429
}

/// The destination clients' logger. Never log URLs, query strings, headers, bodies, tokens or
/// values: only the provider, the method, the status and ``DestinationError/logCode``.
enum DestinationLog {
    static let http = Logger(subsystem: GHConstants.logSubsystem, category: "destinations")
}
