import EnvTools
import Foundation
import VaultCore

/// Public values (v0.8.0, tasks/todo.md R10): a Vercel item under a public prefix
/// (`NEXT_PUBLIC_`, …) ships to every browser. A value that is a known secret token format, a
/// private key or a URL with a password blocks the Sync; a JWT or a long random value only warns,
/// since public keys (an anon key, a publishable key) look like that too. "Mark as Public" clears
/// both.
public enum PublicValuePolicy {
    public enum Verdict: Sendable, Hashable {
        case none
        /// Looks like a token; fine when it is meant to be public.
        case warn(prefix: String)
        /// Looks like a secret: blocks the Sync.
        case block(prefix: String)
    }

    /// The public prefix of a Vercel name, or nil (other providers have no public names).
    public static func publicPrefix(of name: String, provider: DestinationProvider) -> String? {
        provider == .vercel ? PublicNamePrefixes.prefix(of: name) : nil
    }

    /// The verdict for `value` under `name`. Inspects the value in place; nothing is copied.
    public static func verdict(name: String, value: SecretBytes, provider: DestinationProvider, isPublicAllowed: Bool) -> Verdict {
        guard !isPublicAllowed, let prefix = publicPrefix(of: name, provider: provider) else { return .none }
        let reasons = CredentialClassifier.assess(key: "", value: value).reasons
        if reasons.contains(where: isBlocking) {
            return .block(prefix: prefix)
        }
        return reasons.isEmpty ? .none : .warn(prefix: prefix)
    }

    private static func isBlocking(_ reason: CredentialReason) -> Bool {
        switch reason {
        case .knownTokenPrefix, .pemBlock, .urlWithCredentials: true
        case .keyContains, .jsonWebToken, .highEntropy: false
        }
    }
}
