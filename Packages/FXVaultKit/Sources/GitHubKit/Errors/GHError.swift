import Foundation
import VaultCore

/// Every way a gh call can fail (tasks/todo.md §4.4, §8 E). Carries no localized text; the app
/// maps each case in `GHError+Extension.swift`.
///
/// Cases after ``unexpected(exitCode:)`` are additions to the plan's list: they describe
/// failures that happen before gh runs (bad input, untrusted binary) or in the runner itself.
public enum GHError: Error, Sendable, Hashable {
    /// No gh binary was found (or the override path does not exist).
    case notInstalled
    /// A gh candidate was found but failed the trust check (§5.10 `GHLocator`).
    case untrustedBinary(path: String)
    /// gh is older than ``GHVersion/minimum`` (D5).
    case versionTooOld(found: GHVersion, required: GHVersion)
    /// gh has no logged-in account (exit code 4 or "You are not logged into any GitHub hosts").
    case notAuthenticated
    /// GitHub answered 401 / "Bad credentials": the account's token is no longer valid.
    case tokenRevoked
    /// The token lacks a scope. The list holds the scopes gh named, when it named any.
    case missingScopes([String])
    /// "Must have admin rights".
    case adminRequired
    /// "Resource not accessible" or "repository read permissions".
    case writeAccessRequired
    /// The organization enforces SAML SSO. The URL is the authorization link gh printed, if any
    /// (always `https://github.com/...`).
    case samlRequired(URL?)
    /// The GitHub plan does not include the feature (for example environments on a private
    /// Free-plan repository).
    case planGated
    /// The organization does not allow this account to create repositories (§8 C1).
    case orgPolicyForbidsCreate
    /// 404, "Not Found" or "Could not resolve to a Repository". Callers may reclassify it
    /// (freshRepo window, delete-as-done checks).
    case notFound
    /// 422 or "already exists". The associated text is gh's redacted message (first line).
    case validation(String)
    /// GitHub's primary or secondary rate limit.
    case rateLimited
    /// A 5xx response.
    case serverError(status: Int)
    /// gh could not reach GitHub.
    case network
    /// A read timed out (the process was terminated).
    case timeout
    /// A write timed out after the process started: it may or may not have reached GitHub.
    case indeterminate
    /// Anything else, including exit code 2 (cancelled).
    case unexpected(exitCode: Int32)

    // MARK: - Additions (before or around the process)

    /// A name, path segment or flag value failed validation before any argv was built (D29).
    case invalidInput(ValidationError)
    /// An argv builder produced a forbidden flag (§5.10). Never expected in production.
    case forbiddenArgument(String)
    /// gh exited 0 but its output could not be parsed.
    case malformedOutput
    /// gh's output exceeded the runner's cap (`Limits.maxStdoutBytes`).
    case outputTooLarge
    /// FX Vault's own hourly write budget is used up (D12); the remaining items stay pending.
    case writeBudgetExhausted
    /// The gh process could not be started.
    case launchFailed
    /// The calling task was cancelled.
    case cancelled

    /// A stable, value-free identifier for logs (`privacy: .public` is safe).
    public var logCode: String {
        switch self {
        case .notInstalled: "notInstalled"
        case .untrustedBinary: "untrustedBinary"
        case .versionTooOld: "versionTooOld"
        case .notAuthenticated: "notAuthenticated"
        case .tokenRevoked: "tokenRevoked"
        case .missingScopes: "missingScopes"
        case .adminRequired: "adminRequired"
        case .writeAccessRequired: "writeAccessRequired"
        case .samlRequired: "samlRequired"
        case .planGated: "planGated"
        case .orgPolicyForbidsCreate: "orgPolicyForbidsCreate"
        case .notFound: "notFound"
        case .validation: "validation"
        case .rateLimited: "rateLimited"
        case .serverError(let status): "serverError(\(status))"
        case .network: "network"
        case .timeout: "timeout"
        case .indeterminate: "indeterminate"
        case .unexpected(let exitCode): "unexpected(\(exitCode))"
        case .invalidInput: "invalidInput"
        case .forbiddenArgument: "forbiddenArgument"
        case .malformedOutput: "malformedOutput"
        case .outputTooLarge: "outputTooLarge"
        case .writeBudgetExhausted: "writeBudgetExhausted"
        case .launchFailed: "launchFailed"
        case .cancelled: "cancelled"
        }
    }

    /// True for failures that an idempotent command may retry (D12, §7.3 indeterminate outcomes).
    public var isTransient: Bool {
        switch self {
        case .serverError, .network, .timeout, .indeterminate: true
        default: false
        }
    }
}
