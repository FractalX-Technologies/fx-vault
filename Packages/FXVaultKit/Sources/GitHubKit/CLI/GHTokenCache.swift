import Foundation
import os
import VaultCore

/// In-memory cache of each account's `gh auth token` (tasks/todo.md §4.3, §8 A4).
///
/// Lock-protected, with a **synchronous** ``purge()`` so the vault lock path can call it
/// without suspending. Tokens are never written to disk. Every token handed out is a copy the
/// caller wipes; the cache wipes its own buffers on invalidation and purge.
public final class GHTokenCache: Sendable {
    private let tokens = OSAllocatedUnfairLock(initialState: [String: SecretBytes]())

    public init() {}

    /// A copy of the cached token for `login` (case-insensitive), or nil.
    public func token(for login: String) -> SecretBytes? {
        tokens.withLock { $0[Self.key(login)]?.copy() }
    }

    /// Stores `token` for `login`, taking ownership of the buffer. A previous token is wiped.
    public func store(_ token: SecretBytes, for login: String) {
        let previous = tokens.withLock { tokens -> SecretBytes? in
            let key = Self.key(login)
            let previous = tokens[key]
            tokens[key] = token
            return previous
        }
        previous?.wipe()
    }

    /// Wipes and removes the token for `login` (Re-check, `.tokenRevoked`).
    public func invalidate(login: String) {
        let removed = tokens.withLock { $0.removeValue(forKey: Self.key(login)) }
        removed?.wipe()
    }

    /// Wipes and removes every token. Synchronous; safe to call from the lock path.
    public func purge() {
        let removed = tokens.withLock { tokens -> [SecretBytes] in
            let values = Array(tokens.values)
            tokens.removeAll()
            return values
        }
        for token in removed {
            token.wipe()
        }
    }

    /// Number of cached tokens.
    public var count: Int {
        tokens.withLock { $0.count }
    }

    private static func key(_ login: String) -> String {
        OwnerLoginValidator.foldKey(login)
    }
}
