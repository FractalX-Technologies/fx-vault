import Foundation
import os
import VaultCore

/// In-memory cache of each account's `gh auth token` (tasks/todo.md §4.3, §8 A4).
///
/// Lock-protected, with a **synchronous** ``purge()`` so the vault lock path can call it
/// without suspending. Tokens are never written to disk. Every token handed out is a copy the
/// caller wipes; the cache wipes its own buffers on invalidation and purge.
///
/// Each purge starts a new ``generation``. A token fetched across a purge (A4 still running
/// when the vault locked) is stored only with ``store(_:for:ifGeneration:)``, which refuses it,
/// so the lock-time purge (§5.8 Phase A) cannot be undone by a late A4.
public final class GHTokenCache: Sendable {
    private struct State {
        var tokens: [String: SecretBytes] = [:]
        var generation: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// The current purge generation. Read it before a fetch and pass it to
    /// ``store(_:for:ifGeneration:)``.
    public var generation: UInt64 {
        state.withLock { $0.generation }
    }

    /// A copy of the cached token for `login` (case-insensitive), or nil.
    public func token(for login: String) -> SecretBytes? {
        state.withLock { $0.tokens[Self.key(login)]?.copy() }
    }

    /// Stores `token` for `login`, taking ownership of the buffer. A previous token is wiped.
    public func store(_ token: SecretBytes, for login: String) {
        let previous = state.withLock { state -> SecretBytes? in
            let key = Self.key(login)
            let previous = state.tokens[key]
            state.tokens[key] = token
            return previous
        }
        previous?.wipe()
    }

    /// Stores `token` for `login` only if no purge happened since `generation` was read, and
    /// returns true. Otherwise wipes `token` and returns false. Takes ownership of the buffer.
    public func store(_ token: SecretBytes, for login: String, ifGeneration generation: UInt64) -> Bool {
        let outcome = state.withLock { state -> (stored: Bool, previous: SecretBytes?) in
            guard state.generation == generation else { return (false, nil) }
            let key = Self.key(login)
            let previous = state.tokens[key]
            state.tokens[key] = token
            return (true, previous)
        }
        outcome.previous?.wipe()
        if !outcome.stored {
            token.wipe()
        }
        return outcome.stored
    }

    /// Wipes and removes the token for `login` (Re-check, `.tokenRevoked`).
    public func invalidate(login: String) {
        let removed = state.withLock { $0.tokens.removeValue(forKey: Self.key(login)) }
        removed?.wipe()
    }

    /// Wipes and removes every token and starts a new generation. Synchronous; safe to call
    /// from the lock path.
    public func purge() {
        let removed = state.withLock { state -> [SecretBytes] in
            let values = Array(state.tokens.values)
            state.tokens.removeAll()
            state.generation &+= 1
            return values
        }
        for token in removed {
            token.wipe()
        }
    }

    /// Number of cached tokens.
    public var count: Int {
        state.withLock { $0.tokens.count }
    }

    private static func key(_ login: String) -> String {
        OwnerLoginValidator.foldKey(login)
    }
}
