import Foundation

/// A GitHub account logged into gh (`accounts` row, §6 `v2_accounts_repos`).
///
/// Token state and scopes are runtime facts from `gh auth status` and are not part of this model.
public struct AccountModel: Sendable, Hashable, Identifiable {
    /// The GitHub login, as gh reports it. Unique without regard to case (GitHub logins are ASCII).
    public var login: String
    /// Always ``GitHubHostValidator/host`` (`github.com`).
    public var host: String
    /// The `~/.ssh/config` alias mapped to this account, if any.
    public var sshHostAlias: String?
    /// The login that `ssh -T git@<alias>` authenticated as at the last Test.
    public var sshVerifiedLogin: String?
    /// When the alias was last verified.
    public var sshVerifiedAt: Date?
    /// False when gh no longer lists the account (rows are kept for their repositories).
    public var isPresent: Bool
    /// When gh last listed the account.
    public var lastSeenAt: Date

    public init(
        login: String,
        host: String = GitHubHostValidator.host,
        sshHostAlias: String? = nil,
        sshVerifiedLogin: String? = nil,
        sshVerifiedAt: Date? = nil,
        isPresent: Bool = true,
        lastSeenAt: Date
    ) {
        self.login = login
        self.host = host
        self.sshHostAlias = sshHostAlias
        self.sshVerifiedLogin = sshVerifiedLogin
        self.sshVerifiedAt = sshVerifiedAt
        self.isPresent = isPresent
        self.lastSeenAt = lastSeenAt
    }

    /// The case-folded login (logins are case-insensitive ASCII).
    public var id: String {
        OwnerLoginValidator.foldKey(login)
    }

    /// True when the mapped SSH alias authenticated as this account.
    public var isSSHAliasVerified: Bool {
        guard sshHostAlias != nil, let sshVerifiedLogin else { return false }
        return OwnerLoginValidator.foldKey(sshVerifiedLogin) == id
    }
}
