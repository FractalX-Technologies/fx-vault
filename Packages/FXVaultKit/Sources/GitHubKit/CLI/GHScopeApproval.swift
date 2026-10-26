import Foundation
import os

/// A scope FX Vault may ask gh to add (1.0 B4b). The fixed list is the only source of
/// `gh auth refresh -s`: never text from the user or from gh.
public enum GHApprovalScope: String, Sendable, Hashable, CaseIterable {
    case repo
    case readOrg = "read:org"
    case adminOrg = "admin:org"
}

extension GHApprovalScope {
    /// True when `scopes` (gh's list for the account) cover every requested scope, by
    /// ``ScopeChecker``'s rule: `read:org` is met by any organization scope, `admin:org` too.
    public static func areGranted(_ requested: [GHApprovalScope], by scopes: [String]) -> Bool {
        let held = Set(scopes.map { $0.lowercased() })
        let missing: [String]
        if case .missing(let names) = ScopeChecker.check(scopes: held) {
            missing = names
        } else {
            missing = []
        }
        return requested.allSatisfy { scope in
            switch scope {
            case .repo: !missing.contains(ScopeChecker.repoScope)
            case .readOrg: !missing.contains(ScopeChecker.suggestedOrgScope)
            case .adminOrg: held.contains(ScopeChecker.adminOrgScope)
            }
        }
    }
}

/// gh's one-time device code, entered at ``verificationURL``. Shown, never logged.
public struct GHDeviceCodeModel: Sendable, Hashable {
    /// Where the code goes; also the button's title without the scheme.
    public static let verificationHost = "github.com/login/device"
    public static let verificationURL = URL(string: "https://" + verificationHost)

    public let code: String

    public init(code: String) {
        self.code = code
    }
}

/// Why an approval ended without the new scopes.
public enum GHApprovalError: Error, Sendable, Hashable {
    /// Cancel, or the vault locked: gh was stopped.
    case cancelled
    /// The code expired before the approval (``Timeouts/ghAuthRefresh``).
    case timedOut
    /// gh exited non-zero (no browser approval, a `GH_TOKEN` in its environment, no network).
    case failed
    /// gh printed no device code FX Vault recognizes (``Timeouts/ghDeviceCodeWait``).
    case unrecognizedOutput
    /// gh refreshes only its active account; another one needs `gh auth switch` first.
    case notActiveAccount
}

/// Finds the device code in `gh auth refresh`'s stderr, with or without a terminal: gh prints
/// "! First copy your one-time code: 4F2C-91AB", colored on a TTY, then either "Press Enter
/// to open github.com…" or "Open this URL to continue in your web browser: …".
public enum GHDeviceCodeParser {
    // `Regex` isn't `Sendable`: built per call (a few lines, once per chunk).
    public static func deviceCode(in text: String) -> GHDeviceCodeModel? {
        let plain = text.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")
        guard let match = plain.firstMatch(of: /one-time code: ([A-Z0-9]{4}-[A-Z0-9]{4})\b/) else { return nil }
        return GHDeviceCodeModel(code: String(match.output.1))
    }
}

/// Collects stderr chunks until the device code shows, then reports it once.
final class GHDeviceCodeWatcher: Sendable {
    private struct State {
        var text = ""
        var code: GHDeviceCodeModel?
    }

    /// A code sits in the first lines; more is never needed.
    private static let maxCharacters = 4096
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onCode: @Sendable (GHDeviceCodeModel) -> Void

    init(onCode: @escaping @Sendable (GHDeviceCodeModel) -> Void) {
        self.onCode = onCode
    }

    var hasCode: Bool {
        state.withLock { $0.code != nil }
    }

    func receive(_ chunk: String) {
        let found = state.withLock { state -> GHDeviceCodeModel? in
            guard state.code == nil, state.text.count < Self.maxCharacters else { return nil }
            state.text += chunk
            state.code = GHDeviceCodeParser.deviceCode(in: state.text)
            return state.code
        }
        if let found { onCode(found) }
    }
}
