import Foundation
import VaultCore

/// Every way a destination call can fail (v0.8.0). Carries no localized text and no provider
/// message (messages may quote names); the app maps each case.
///
/// Provider error codes are kept only as short identifiers (``sanitizedCode(_:)``).
public enum DestinationError: Error, Sendable, Hashable {
    // MARK: - Azure CLI

    /// No `az` was found (or the override path does not exist).
    case azNotInstalled
    /// An `az` was found but failed the trust check (the first candidate that exists decides).
    case azUntrusted(path: String)
    /// `az` has no usable login for the tenant ("Please run 'az login'").
    case azNotSignedIn
    /// `az account get-access-token` failed otherwise (exit code, or
    /// ``AzureCLITokenProvider/launchFailedExitCode`` when it could not start).
    case azFailed(exitCode: Int32)

    // MARK: - Credentials

    /// No personal access token for Supabase or Vercel, or one that is empty or not printable
    /// ASCII.
    case tokenMissing
    /// HTTP 401: the token is not valid (Key Vault: after one refresh of the `az` token).
    case unauthorized
    /// HTTP 403 (or 402): the account may not do this (RBAC, access policy, firewall, plan).
    case forbidden

    // MARK: - Provider answers

    /// HTTP 404 or 410.
    case notFound
    /// Key Vault: the name belongs to a soft-deleted secret (`ObjectIsDeletedButRecoverable`).
    case deletedButRecoverable
    /// HTTP 409 (or Vercel's "already exists"), with the provider's code.
    case conflict(code: String?)
    /// HTTP 429 after the retries; `retryAfter` is the provider's `Retry-After`, when it sent one.
    case rateLimited(retryAfter: Duration?)
    /// Another 4xx, or a request FX Vault refuses itself (``LocalCode``), with a code.
    case invalidRequest(code: String?)
    /// The value is larger than the provider accepts (FX Vault's check before sending, or 413).
    case valueTooLarge
    /// HTTP 5xx after the retries.
    case server(status: Int)
    /// No answer: not connected, host not found, connection lost, TLS failure.
    case network
    /// The request timed out (it may have reached the provider).
    case timeout
    /// The answer could not be read (malformed JSON, a missing required field).
    case decoding
    /// The calling task was cancelled.
    case cancelled
    /// A URL (request, `nextLink`, redirect) pointed outside the allowlist, or the provider
    /// answered with a redirect, which FX Vault never follows.
    case disallowedHost

    // MARK: - Additions

    /// The answer was larger than `Limits.maxDestinationResponseBytes`, or a listing had more
    /// than FX Vault's page limit.
    case responseTooLarge
    /// The value is not valid UTF-8, so it cannot travel in a JSON body.
    case valueNotUTF8
    /// A name or target failed FX Vault's validation before any request was built.
    case invalidInput(ValidationError)

    /// Codes of ``invalidRequest(code:)`` that FX Vault produces itself, before sending.
    public enum LocalCode {
        /// ``DestinationRemoting/readValue(of:)`` on an item whose value the provider never
        /// returns (Supabase, a Vercel `sensitive` or system variable, a disabled secret).
        public static let writeOnly = "writeOnly"
        /// A Vercel item without a usable environment variable id (missing, or not an
        /// identifier) for a read, update or delete.
        public static let missingRemoteRef = "missingRemoteRef"
        /// A header value with a line break, or a reserved header (programming error).
        public static let invalidHeader = "invalidHeader"
        /// An unmatched request in ``FakeHTTPTransport`` (tests only).
        public static let fakeUnmatched = "fakeUnmatched"

        static let all: Set<String> = [writeOnly, missingRemoteRef, invalidHeader, fakeUnmatched]
    }

    /// A stable, value-free identifier for logs (`privacy: .public` is safe). Provider codes are
    /// already sanitized; paths are left out.
    public var logCode: String {
        switch self {
        case .azNotInstalled: "azNotInstalled"
        case .azUntrusted: "azUntrusted"
        case .azNotSignedIn: "azNotSignedIn"
        case .azFailed(let exitCode): "azFailed(\(exitCode))"
        case .tokenMissing: "tokenMissing"
        case .unauthorized: "unauthorized"
        case .forbidden: "forbidden"
        case .notFound: "notFound"
        case .deletedButRecoverable: "deletedButRecoverable"
        case .conflict(let code): "conflict(\(code ?? "-"))"
        case .rateLimited: "rateLimited"
        case .invalidRequest(let code): "invalidRequest(\(code ?? "-"))"
        case .valueTooLarge: "valueTooLarge"
        case .server(let status): "server(\(status))"
        case .network: "network"
        case .timeout: "timeout"
        case .decoding: "decoding"
        case .cancelled: "cancelled"
        case .disallowedHost: "disallowedHost"
        case .responseTooLarge: "responseTooLarge"
        case .valueNotUTF8: "valueNotUTF8"
        case .invalidInput: "invalidInput"
        }
    }

    /// True for failures worth retrying later: 5xx, network and timeout (as `GHError`). The
    /// clients already retried idempotent requests before throwing.
    public var isTransient: Bool {
        switch self {
        case .server, .network, .timeout: true
        default: false
        }
    }

    /// True when the error comes from the provider's answer (an HTTP status arrived). False
    /// when no answer arrived (network, timeout, cancelled; a write may still have been
    /// applied) and for failures before anything was sent (az, token, host, size, encoding and
    /// name checks, ``LocalCode``).
    public var reachedProvider: Bool {
        switch self {
        case .unauthorized, .forbidden, .notFound, .deletedButRecoverable, .conflict, .rateLimited,
             .server, .decoding, .responseTooLarge:
            true
        case .invalidRequest(let code):
            !(code.map(LocalCode.all.contains) ?? false)
        case .azNotInstalled, .azUntrusted, .azNotSignedIn, .azFailed, .tokenMissing, .valueTooLarge,
             .network, .timeout, .cancelled, .disallowedHost, .valueNotUTF8, .invalidInput:
            false
        }
    }

    /// `code` when it is 1–64 characters of `[A-Za-z0-9_.-]`, else nil. Provider messages are
    /// never kept; codes are identifiers such as `ObjectIsDeletedButRecoverable` or
    /// `ENV_ALREADY_EXISTS`.
    public static func sanitizedCode(_ code: String?) -> String? {
        guard let code, (1...DestinationConstants.maxErrorCodeLength).contains(code.unicodeScalars.count) else {
            return nil
        }
        let isIdentifier = code.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "_" || scalar == "." || scalar == "-"
        }
        return isIdentifier ? code : nil
    }
}
