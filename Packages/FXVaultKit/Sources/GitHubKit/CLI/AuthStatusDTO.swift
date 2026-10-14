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

    public init(
        login: String,
        isActive: Bool,
        state: GHAccountState,
        scopes: ScopeStatus,
        scopeList: [String]?,
        gitProtocol: String?
    ) {
        self.login = login
        self.isActive = isActive
        self.state = state
        self.scopes = scopes
        self.scopeList = scopeList
        self.gitProtocol = gitProtocol
    }

    /// The lowercase login.
    public var id: String {
        OwnerLoginValidator.foldKey(login)
    }

    private static let successState = "success"
    private static let timeoutState = "timeout"

    /// Maps the github.com entries; entries with invalid logins are skipped.
    public static func accounts(from dto: AuthStatusDTO) -> [GHAccountStatusModel] {
        dto.gitHubEntries.compactMap { entry in
            guard OwnerLoginValidator.isValid(entry.login) else { return nil }
            return GHAccountStatusModel(
                login: entry.login,
                isActive: entry.active,
                state: state(of: entry),
                scopes: ScopeChecker.check(entry.scopes),
                scopeList: ScopeChecker.parse(entry.scopes),
                gitProtocol: entry.gitProtocol
            )
        }
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
