import GitHubKit
import Observation
import SyncEngine
import VaultData

/// Whether GitHub answers the gh calls FX Vault already makes (v0.2.0 "GitHub isn't responding"
/// banner). It never calls GitHub itself: view models report the outcome of their own gh-backed
/// calls with ``record(_:)`` and ``recordSuccess()``.
///
/// - `GHError.network` and `.timeout` (after the scheduler's own retries) mean GitHub did not
///   answer.
/// - A success, or any error GitHub itself returned (404, 422, 401, rate limit, 5xx, SAML),
///   means it answered.
/// - Local failures (gh missing, a cancelled task, the vault, the database) say nothing.
@Observable
final class GitHubReachability {
    /// False after a gh call could not reach GitHub, until one succeeds.
    private(set) var isResponding = true
    /// True while ``retry(_:)`` runs the caller's calls again.
    private(set) var isRetrying = false

    /// Counts reports, so ``retry(_:)`` can tell whether its calls reported anything.
    @ObservationIgnored private var reportCount = 0

    /// Records the outcome of a failed gh-backed call (any error a repository threw).
    func record(_ error: any Error) {
        guard let reached = error.gitHubFailure?.reachedGitHub else { return }
        report(isResponding: reached)
    }

    /// Records a gh-backed call that succeeded.
    func recordSuccess() {
        report(isResponding: true)
    }

    /// Forgets the last state (the internet connection came back).
    func reset() {
        isResponding = true
    }

    /// **Retry** on the banner: runs `calls` (gh calls the app already makes, which report their
    /// outcomes here). When none of them reported anything (gh not ready, nothing open), the
    /// banner goes away; it comes back with the next failure.
    func retry(_ calls: () async -> Void) async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        let before = reportCount
        await calls()
        if reportCount == before {
            isResponding = true
        }
    }

    private func report(isResponding responding: Bool) {
        reportCount += 1
        isResponding = responding
    }
}

nonisolated extension GHError {
    /// True when GitHub answered, false when it could not be reached, nil for failures before or
    /// around the gh process that say nothing about GitHub.
    var reachedGitHub: Bool? {
        switch self {
        case .network, .timeout:
            false
        case .tokenRevoked, .missingScopes, .adminRequired, .writeAccessRequired, .samlRequired, .planGated,
             .orgPolicyForbidsCreate, .notFound, .validation, .rateLimited, .serverError:
            true
        case .notInstalled, .untrustedBinary, .versionTooOld, .notAuthenticated, .indeterminate, .unexpected,
             .invalidInput, .forbiddenArgument, .malformedOutput, .outputTooLarge, .writeBudgetExhausted,
             .launchFailed, .cancelled:
            nil
        }
    }
}

nonisolated extension Error {
    /// The gh failure inside an error a VaultData repository threw, if any.
    var gitHubFailure: GHError? {
        switch self {
        case let error as GHError:
            error
        case let error as RepoCatalogError:
            if case .github(let failure) = error { failure } else { nil }
        case let error as DriftRepositoryError:
            switch error {
            case .github(let failure), .sync(.github(let failure)): failure
            default: nil
            }
        case let error as GitHubEnvironmentError:
            if case .github(let failure) = error { failure } else { nil }
        case let error as RepoCreationError:
            if case .github(let failure) = error { failure } else { nil }
        case let error as SyncRepositoryError:
            if case .sync(.github(let failure)) = error { failure } else { nil }
        case let error as SyncError:
            if case .github(let failure) = error { failure } else { nil }
        default:
            nil
        }
    }
}
