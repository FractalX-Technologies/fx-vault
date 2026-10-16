import Foundation
import VaultCore

/// What FX Vault knows about the GitHub CLI, for `FX Vault --diagnose` (its `gh` section) and
/// the setup screen's Copy Diagnostics (v0.3.1).
///
/// It holds paths, versions, codes, the **names** of shell variables and account logins with
/// their states. Never a token, a secret, or the value of an environment variable: the shell
/// probe never reads token values, `gh auth status --json hosts` never prints a token, account
/// error messages are reduced to a code, and token sources are kept only when they are one of
/// gh's known names.
///
/// JSON (keys sorted by the encoder; absent values are `null`, never omitted):
/// ```json
/// "gh": {
///   "accounts": [{"isActive": true, "login": "user-a", "missingScopes": [], "scopes": "ok",
///                 "state": "ok", "tokenSource": "keyring"}],
///   "accountsChecked": true, "accountsError": null,
///   "candidates": [{"isChosen": true, "isTrustedByConsent": false, "ownerName": null,
///                   "ownerUID": null, "path": "/opt/homebrew/bin/gh", "reason": null,
///                   "resolvedPath": "/opt/homebrew/Cellar/gh/2.102.0/bin/gh", "source": "shell",
///                   "status": "accepted", "version": "2.102.0", "versionError": null}],
///   "chosenPath": "/opt/homebrew/bin/gh", "overridePath": null, "result": "ready",
///   "shell": {"ghPath": "/opt/homebrew/bin/gh", "path": "/bin/zsh", "probeMode": "interactive",
///             "variablesSet": ["GH_CONFIG_DIR"]},
///   "trustedBinary": null, "unusableAccounts": []
/// }
/// ```
public struct GHDiagnosticsModel: Sendable, Hashable, Encodable {
    /// The shell probe (§8 A2).
    public struct ShellSection: Sendable, Hashable, Encodable {
        /// The probed shell, for example `/bin/zsh`.
        public let path: String?
        public let probeMode: ShellProbeMode
        /// `command -v gh` in that shell.
        public let ghPath: String?
        /// Which of `GH_TOKEN`, `GITHUB_TOKEN`, `GH_CONFIG_DIR`, `XDG_CONFIG_HOME`, `GH_HOST` the
        /// shell exports, sorted. Names only.
        public let variablesSet: [String]

        private enum CodingKeys: String, CodingKey {
            case path, probeMode, ghPath, variablesSet
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(probeMode, forKey: .probeMode)
            try container.encode(ghPath, forKey: .ghPath)
            try container.encode(variablesSet, forKey: .variablesSet)
        }
    }

    /// One gh candidate.
    public struct CandidateEntry: Sendable, Hashable, Encodable {
        public let path: String
        public let source: GHCandidateSource
        public let resolvedPath: String?
        /// `gh --version`, when it ran (never for a rejected binary).
        public let version: String?
        /// `accepted`, `rejected` or `notFound`.
        public let status: String
        /// The ``GHBinaryRejection`` code when rejected.
        public let reason: String?
        /// The one other user who owns the file or a folder.
        public let ownerUID: UInt32?
        public let ownerName: String?
        public let isTrustedByConsent: Bool
        /// The candidate that decided the result.
        public let isChosen: Bool
        /// `GHError.logCode` when `gh --version` failed.
        public let versionError: String?

        private enum CodingKeys: String, CodingKey {
            case path, source, resolvedPath, version, status, reason, ownerUID, ownerName
            case isTrustedByConsent, isChosen, versionError
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(source, forKey: .source)
            try container.encode(resolvedPath, forKey: .resolvedPath)
            try container.encode(version, forKey: .version)
            try container.encode(status, forKey: .status)
            try container.encode(reason, forKey: .reason)
            try container.encode(ownerUID, forKey: .ownerUID)
            try container.encode(ownerName, forKey: .ownerName)
            try container.encode(isTrustedByConsent, forKey: .isTrustedByConsent)
            try container.encode(isChosen, forKey: .isChosen)
            try container.encode(versionError, forKey: .versionError)
        }
    }

    /// One account gh lists on github.com that FX Vault can use.
    public struct AccountEntry: Sendable, Hashable, Encodable {
        public let login: String
        public let isActive: Bool
        /// ``GHAccountState/code``.
        public let state: String
        /// One of gh's known token source names, `other`, or null.
        public let tokenSource: String?
        /// `ok`, `missing` or `unknown`.
        public let scopes: String
        public let missingScopes: [String]

        private enum CodingKeys: String, CodingKey {
            case login, isActive, state, tokenSource, scopes, missingScopes
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(login, forKey: .login)
            try container.encode(isActive, forKey: .isActive)
            try container.encode(state, forKey: .state)
            try container.encode(tokenSource, forKey: .tokenSource)
            try container.encode(scopes, forKey: .scopes)
            try container.encode(missingScopes, forKey: .missingScopes)
        }
    }

    /// One account gh lists that FX Vault cannot use.
    public struct UnusableAccountEntry: Sendable, Hashable, Encodable {
        /// The login cleaned for display.
        public let login: String
        public let isActive: Bool
        /// The `NameRule` the login broke.
        public let reason: String
    }

    /// The gh the user chose to trust (Preferences › Advanced).
    public struct TrustEntry: Sendable, Hashable, Encodable {
        public let path: String
        public let ownerUID: UInt32
        public let ownerName: String?

        private enum CodingKeys: String, CodingKey {
            case path, ownerUID, ownerName
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(ownerUID, forKey: .ownerUID)
            try container.encode(ownerName, forKey: .ownerName)
        }
    }

    public static let readyResult = "ready"
    public static let acceptedStatus = "accepted"
    public static let rejectedStatus = "rejected"
    public static let notFoundStatus = "notFound"
    /// A token source gh reported that is not one of its known names.
    public static let otherTokenSource = "other"
    /// gh's token source names (`gh auth status`): its keyring, its config file, the token
    /// variables.
    public static let knownTokenSources: Set<String> = [
        "keyring", "oauth_token", "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
    ]

    public let shell: ShellSection
    public let overridePath: String?
    public let trustedBinary: TrustEntry?
    public let candidates: [CandidateEntry]
    /// The candidate that decided the result: the gh in use when ``result`` is `ready`.
    public let chosenPath: String?
    /// `ready`, or the `GHError.logCode` of the failure (`notInstalled`, `untrustedBinary`,
    /// `versionTooOld`, …).
    public let result: String
    /// True when `gh auth status` ran (only after a gh was accepted).
    public let accountsChecked: Bool
    public let accounts: [AccountEntry]
    public let unusableAccounts: [UnusableAccountEntry]
    /// `GHError.logCode` when `gh auth status` failed.
    public let accountsError: String?

    /// Builds the sections from what detection and A3 returned.
    public init(
        shell: ShellEnvironmentModel,
        overridePath: String?,
        trustedBinary: GHTrustedBinaryModel?,
        trustedOwnerName: String?,
        report: GHLocatorReportModel,
        listing: GHAccountListingModel?,
        accountsError: GHError?
    ) {
        self.shell = ShellSection(
            path: shell.shellPath,
            probeMode: shell.probeMode,
            ghPath: shell.ghPath,
            variablesSet: shell.setVariables.sorted().map(\.rawValue)
        )
        self.overridePath = overridePath
        self.trustedBinary = trustedBinary.map {
            TrustEntry(path: $0.path, ownerUID: $0.ownerUID, ownerName: trustedOwnerName)
        }
        candidates = report.candidates.enumerated().map { index, candidate in
            Self.entry(candidate, isChosen: index == report.decisiveIndex)
        }
        chosenPath = report.decisive?.path
        switch report.outcome {
        case .success:
            result = Self.readyResult
        case .failure(let error):
            result = error.logCode
        }
        accountsChecked = listing != nil || accountsError != nil
        accounts = (listing?.accounts ?? []).map(Self.entry)
        unusableAccounts = (listing?.unusable ?? []).map {
            UnusableAccountEntry(login: $0.displayLogin, isActive: $0.isActive, reason: $0.violation.diagnosticCode)
        }
        self.accountsError = accountsError?.logCode
    }

    /// A report for when nothing could run (for example the empty working directory could not
    /// be prepared): `result` is `error`'s code, nothing was inspected.
    public static func unavailable(
        _ error: GHError,
        overridePath: String?,
        trustedBinary: GHTrustedBinaryModel?
    ) -> GHDiagnosticsModel {
        GHDiagnosticsModel(
            shell: .empty,
            overridePath: overridePath,
            trustedBinary: trustedBinary,
            trustedOwnerName: nil,
            report: GHLocatorReportModel(candidates: [], decisiveIndex: nil, outcome: .failure(error)),
            listing: nil,
            accountsError: nil
        )
    }

    private static func entry(_ candidate: GHCandidateReportModel, isChosen: Bool) -> CandidateEntry {
        let status = switch candidate.rejection {
        case nil: acceptedStatus
        case .notFound: notFoundStatus
        default: rejectedStatus
        }
        let isNotFound = candidate.rejection == .notFound
        return CandidateEntry(
            path: candidate.path,
            source: candidate.source,
            resolvedPath: candidate.resolvedPath,
            version: candidate.version?.description,
            status: status,
            reason: isNotFound ? nil : candidate.rejection?.rawValue,
            ownerUID: candidate.foreignOwner?.uid,
            ownerName: candidate.foreignOwner?.name,
            isTrustedByConsent: candidate.isTrustedByConsent,
            isChosen: isChosen,
            versionError: candidate.versionFailure?.logCode
        )
    }

    private static func entry(_ account: GHAccountStatusModel) -> AccountEntry {
        let scopes: String
        var missing: [String] = []
        switch account.scopes {
        case .ok:
            scopes = "ok"
        case .missing(let names):
            scopes = "missing"
            missing = names
        case .unknown:
            scopes = "unknown"
        }
        return AccountEntry(
            login: account.login,
            isActive: account.isActive,
            state: account.state.code,
            tokenSource: account.tokenSource.map { knownTokenSources.contains($0) ? $0 : otherTokenSource },
            scopes: scopes,
            missingScopes: missing
        )
    }

    private enum CodingKeys: String, CodingKey {
        case shell, overridePath, trustedBinary, candidates, chosenPath, result
        case accountsChecked, accounts, unusableAccounts, accountsError
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shell, forKey: .shell)
        try container.encode(overridePath, forKey: .overridePath)
        try container.encode(trustedBinary, forKey: .trustedBinary)
        try container.encode(candidates, forKey: .candidates)
        try container.encode(chosenPath, forKey: .chosenPath)
        try container.encode(result, forKey: .result)
        try container.encode(accountsChecked, forKey: .accountsChecked)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(unusableAccounts, forKey: .unusableAccounts)
        try container.encode(accountsError, forKey: .accountsError)
    }
}

extension NameRule {
    /// A stable, value-free code for diagnostics (`invalidCharacter`, `tooLong`, …).
    var diagnosticCode: String {
        switch self {
        case .empty: "empty"
        case .tooLong: "tooLong"
        case .invalidCharacter: "invalidCharacter"
        case .invalidFirstCharacter: "invalidFirstCharacter"
        case .leadingDigit: "leadingDigit"
        case .reservedPrefix: "reservedPrefix"
        case .reservedName: "reservedName"
        case .dotName: "dotName"
        case .gitSuffix: "gitSuffix"
        case .controlCharacter: "controlCharacter"
        case .bidiCharacter: "bidiCharacter"
        case .zeroWidthCharacter: "zeroWidthCharacter"
        case .leadingOrTrailingWhitespace: "leadingOrTrailingWhitespace"
        case .notNormalized: "notNormalized"
        }
    }
}
