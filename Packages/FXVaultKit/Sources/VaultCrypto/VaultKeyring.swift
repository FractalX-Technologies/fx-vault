import os
import VaultCore

/// Holds the unlocked keys of the vault while it is unlocked (§4.3).
///
/// - ``withKeys(_:)`` copies the keys out while holding the lock, **releases the lock**, then runs
///   the synchronous, non-escaping body. Nested calls are safe and ``lock()`` never waits behind
///   bulk work.
/// - ``lock()`` drops the keys and increments ``generation``. Work that read keys before a lock
///   fails ``ensureCurrent(_:)`` with `VaultError.locked` and must not commit.
/// - The keyring holds the only long-lived reference to the key material. Once ``lock()`` has
///   run and in-flight bodies have returned, the material is released and CryptoKit zeroes it.
public final class VaultKeyring: Sendable {
    private struct State: Sendable {
        var keys: UnlockedKeys?
        var generation: UInt64
    }

    private let state = OSAllocatedUnfairLock(initialState: State(keys: nil, generation: 0))

    public init() {}

    /// True when no keys are installed.
    public var isLocked: Bool {
        state.withLock { $0.keys == nil }
    }

    /// Increments on every ``install(_:)`` and ``lock()``.
    public var generation: UInt64 {
        state.withLock { $0.generation }
    }

    /// Installs `keys` (after an unlock or a committed rotation) and returns the new generation.
    @discardableResult
    public func install(_ keys: UnlockedKeys) -> UInt64 {
        state.withLock { state in
            state.generation &+= 1
            var installed = keys
            installed.generation = state.generation
            state.keys = installed
            return state.generation
        }
    }

    /// Drops the keys synchronously (Phase A of the lock procedure, §5.8). Idempotent apart from
    /// the generation bump.
    public func lock() {
        let released: UnlockedKeys? = state.withLock { state in
            state.generation &+= 1
            let previous = state.keys
            state.keys = nil
            return previous
        }
        // `released` is dropped here, outside the lock.
        _ = released
    }

    /// Runs `body` with a snapshot of the keys.
    ///
    /// The body must be synchronous and must not keep the keys (the parameter is `borrowing`).
    /// Long jobs call this once per item so a lock takes effect between items.
    ///
    /// - Throws: `VaultError.locked` when the vault is locked, or whatever `body` throws.
    public func withKeys<Result>(_ body: (borrowing UnlockedKeys) throws -> Result) throws -> Result {
        let snapshot: UnlockedKeys? = state.withLock { $0.keys }
        guard let snapshot else { throw VaultError.locked }
        return try body(snapshot)
    }

    /// Throws `VaultError.locked` unless `generation` is still current (no lock or re-install
    /// happened since the keys were read). Call right before committing.
    public func ensureCurrent(_ generation: UInt64) throws(VaultError) {
        let isCurrent = state.withLock { $0.keys != nil && $0.generation == generation }
        guard isCurrent else { throw .locked }
    }

    /// Test hook: the current key storage object, so tests can hold a weak reference and prove it
    /// is released after ``lock()``.
    func keyStorageForTesting() -> AnyObject? {
        let material: UnlockedKeys.Material? = state.withLock { $0.keys?.material }
        return material
    }
}
