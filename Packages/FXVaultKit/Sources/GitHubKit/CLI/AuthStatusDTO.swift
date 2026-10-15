import Foundation
import VaultCore

/// `gh auth status --hostname github.com --json hosts` (tasks/todo.md §8 A3).
///
/// With `--json` gh always exits 0 and never includes the token (no `--show-token`). With no
/// accounts it prints `{"hosts":{}}`. `scopes` and `error` are `omitempty`.
public struct AuthStatusDTO: Sendable, Hashable, Decodable {
    public struct EntryDTO: Sendable, Hashable, Decodable {
        /// `success`, `timeout` or `error`.
        public let state: String
        public let error: String?
        public let active: Bool
        public let host: String
        public let login: String
        public let tokenSource: String?
        public let scopes: String?
        public let gitProtocol: String?
    }

    public let hosts: [String: [EntryDTO]]

    /// The entries for github.com only.
    public var gitHubEntries: [EntryDTO] {
        hosts[GHConstants.host] ?? []
    }
}

/// How an account's login check went.
public enum GHAccountState: Sendable, Hashable {
    /// `state: success`.
    case ok
    /// `state: timeout`, or an `error` with a network fragment.
    case offline
    /// `error` with `HTTP 401` / `Bad credentials`: run `gh auth login` again.
    case reloginRequired
    /// Any other error (the redacted message).
    case unexpected(String)

    /// A stable, value-free identifier (diagnostics): `ok`, `offline`, `reloginRequired` or
    /// `unexpected` (the message is left out).
    public var code: String {
        switch self {
        case .ok: "ok"
        case .offline: "offline"
        case .reloginRequired: "reloginRequired"
        case .unexpected: "unexpected"
        }
    }
}

/// One gh account on github.com, as `gh auth status` reports it.
public struct GHAccountStatusModel: Sendable, Hashable, Identifiable {
    public let login: String
    public let isActive: Bool
    public let state: GHAccountState
    public let scopes: ScopeStatus
    /// The parsed scope list; nil when unknown.
    public let scopeList: [String]?
    public let gitProtocol: String?
    /// Where gh found the token (`keyring`, `oauth_token` for the config file, or the name of an
    /// environment variable), as gh names it. Never the token. FX Vault never passes `GH_TOKEN`
    /// or `GITHUB_TOKEN` to `gh auth status`, so for its own calls this is a stored credential.
    public let tokenSource: String?

    public init(
        login: String,
        isActive: Bool,
        state: GHAccountState,
        scopes: ScopeStatus,
        scopeList: [String]?,
        gitProtocol: String?,
        tokenSource: String? = nil
    ) {
        self.login = login
        self.isActive = isActive
        self.state = state
        self.scopes = scopes
        self.scopeList = scopeList
        self.gitProtocol = gitProtocol
        self.tokenSource = tokenSource
    }

    /// The lowercase login.
    public var id: String {
        OwnerLoginValidator.foldKey(login)
    }

    private static let successState = "success"
    private static let timeoutState = "timeout"

    /// The usable github.com accounts (logins that pass `OwnerLoginValidator`). Entries with
    /// other logins are in ``GHAccountListingModel/unusable``; never drop them without showing
    /// them (v0.3.1).
    public static func accounts(from dto: AuthStatusDTO) -> [GHAccountStatusModel] {
        GHAccountListingModel(dto: dto).accounts
    }

    static func make(from entry: AuthStatusDTO.EntryDTO) -> GHAccountStatusModel {
        GHAccountStatusModel(
            login: entry.login,
            isActive: entry.active,
            state: state(of: entry),
            scopes: ScopeChecker.check(entry.scopes),
            scopeList: ScopeChecker.parse(entry.scopes),
            gitProtocol: entry.gitProtocol,
            tokenSource: entry.tokenSource
        )
    }

    static func state(of entry: AuthStatusDTO.EntryDTO) -> GHAccountState {
        switch entry.state {
        case successState:
            return .ok
        case timeoutState:
            return .offline
        default:
            let message = StderrRedactor.redact(entry.error ?? "")
            if GHStderrClassifier.isBadCredentials(message) { return .reloginRequired }
            if GHStderrClassifier.isNetworkFailure(message) { return .offline }
            return .unexpected(GHStderrClassifier.message(from: message))
        }
    }
}

/// An account gh lists on github.com whose login FX Vault cannot use (v0.3.1). Before 0.3.1 such
/// accounts were dropped silently, which hid every Enterprise Managed User account (`name_code`)
/// and showed "Log in to GitHub" although gh was logged in. They are now shown with the reason.
public struct GHUnusableAccountModel: Sendable, Hashable {
    /// The login as gh printed it, cleaned for display: token patterns redacted
    /// (``StderrRedactor``), then control, bidi and invisible characters removed and cut to
    /// `Limits.maxDisplayNameBytes` (``DisplayNameSanitizer``). May be empty.
    public let displayLogin: String
    /// The ``OwnerLoginValidator`` rule the login broke.
    public let violation: NameRule
    public let isActive: Bool

    public init(displayLogin: String, violation: NameRule, isActive: Bool) {
        self.displayLogin = displayLogin
        self.violation = violation
        self.isActive = isActive
    }
}

/// Every github.com account of one `gh auth status` (A3): the ones FX Vault can use and the ones
/// it cannot, with the reason.
public struct GHAccountListingModel: Sendable, Hashable {
    public let accounts: [GHAccountStatusModel]
    public let unusable: [GHUnusableAccountModel]

    public init(accounts: [GHAccountStatusModel], unusable: [GHUnusableAccountModel] = []) {
        self.accounts = accounts
        self.unusable = unusable
    }

    /// Splits the github.com entries by ``OwnerLoginValidator``.
    public init(dto: AuthStatusDTO) {
        var accounts: [GHAccountStatusModel] = []
        var unusable: [GHUnusableAccountModel] = []
        for entry in dto.gitHubEntries {
            if let violation = OwnerLoginValidator.violation(in: entry.login) {
                unusable.append(GHUnusableAccountModel(
                    displayLogin: DisplayNameSanitizer.sanitize(StderrRedactor.redactTokenPatterns(in: entry.login)),
                    violation: violation,
                    isActive: entry.active
                ))
            } else {
                accounts.append(GHAccountStatusModel.make(from: entry))
            }
        }
        self.init(accounts: accounts, unusable: unusable)
    }

    /// No account at all.
    public static let empty = GHAccountListingModel(accounts: [])
}
