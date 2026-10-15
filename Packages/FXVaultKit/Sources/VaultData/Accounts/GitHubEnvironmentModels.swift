import Foundation
import GitHubKit
import VaultCore
import VaultStore

/// Hands out the per-account gh queue (D12). ``GitHubEnvironmentRepository`` implements it;
/// tests and previews inject their own.
public protocol GHSchedulerProviding: Sendable {
    /// The one ``GHCommandScheduler`` of `accountLogin` (any case), seeded from the journal.
    func scheduler(for accountLogin: String) async throws(GHError) -> GHCommandScheduler
}

/// One account as Preferences › Accounts and the sidebar show it: the stored row (SSH alias
/// mapping, presence) plus what `gh auth status` reported this time.
public struct GHAccountSummaryModel: Sendable, Hashable, Identifiable {
    /// The `accounts` row.
    public let account: AccountModel
    /// gh's view of the account; nil when gh no longer lists it (its repositories stay).
    public let status: GHAccountStatusModel?

    public init(account: AccountModel, status: GHAccountStatusModel?) {
        self.account = account
        self.status = status
    }

    /// The lowercase login.
    public var id: String {
        account.id
    }

    /// True when gh lists the account.
    public var isLoggedIn: Bool {
        status != nil
    }
}

/// The result of the **Test** button for an SSH alias (D19, §8 D1–D2, §10 Preferences).
public enum SSHAliasTestResultModel: Sendable, Hashable {
    /// "Authenticates as <login>": the alias reaches github.com with the account's key.
    case authenticatedAsAccount(login: String)
    /// The key authenticates as another GitHub account. `isLoggedIntoGH` false is the "which is
    /// not logged into gh" variant.
    case authenticatedAsOtherAccount(login: String, isLoggedIntoGH: Bool)
    /// `ssh -G` resolves the alias to another host.
    case notGitHub(hostName: String)
    /// `Permission denied`: no usable key for the alias.
    case permissionDenied
    /// `Host key verification failed`: run `ssh -T git@<alias>` once in Terminal.
    case hostKeyUnknown
    /// ssh did not finish in time.
    case timeout
    /// Anything else.
    case failed(exitCode: Int32)

    /// True only for ``authenticatedAsAccount(login:)``.
    public var isVerified: Bool {
        if case .authenticatedAsAccount = self { return true }
        return false
    }
}

/// Why a ``GitHubEnvironmentRepository`` operation failed. Carries no localized text.
public enum GitHubEnvironmentError: Error, Sendable, Hashable {
    /// gh detection, auth or a gh command failed.
    case github(GHError)
    /// ssh failed before producing a result (invalid alias, launch failure, cancellation).
    case ssh(GitError)
    /// The local database failed.
    case store(StoreError)
    /// No `accounts` row for the login.
    case accountNotFound
    /// An error of an unknown type (never expected).
    case unexpected

    static func wrap(_ error: any Error) -> GitHubEnvironmentError {
        switch error {
        case let error as GitHubEnvironmentError: error
        case let error as GHError: .github(error)
        case let error as GitError: .ssh(error)
        case let error as StoreError: .store(error)
        default: .unexpected
        }
    }
}
