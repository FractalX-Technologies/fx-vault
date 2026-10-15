import Foundation
import os
import VaultCore

/// An in-memory ``BiometricKeyStoring`` for tests and previews (§12.2). Never shows a prompt and
/// never touches the keychain.
///
/// Scripting:
/// - ``invalidateItems()`` behaves like an enrollment change: items stay present but every read
///   throws `.biometryInvalidated`.
/// - ``failNextLoad(with:)`` makes the next read throw (cancel, lockout, ...).
/// - ``replaceItem(account:with:)`` swaps the stored bytes (a tampered or foreign item).
/// - ``onNextLoad(_:)`` runs code while the next "prompt" is up.
///
/// Counters (`loadCount`, `invalidateCount`, `deletedAccounts`) let tests assert what ran.
public final class FakeBiometricKeyStore: BiometricKeyStoring {
    private struct State: Sendable {
        var items: [String: Data] = [:]
        var invalidated = false
        var nextLoadError: VaultError?
        var storeError: VaultError?
        var loadCount = 0
        var invalidateCount = 0
        var deletedAccounts: [String] = []
        var lastPrompt: BiometricPrompt?
        var nextLoadAction: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    // MARK: - Scripting

    /// Adds an item directly (for example an orphan of an older vault).
    public func seedItem(account: String, bytes: Data) {
        state.withLock { $0.items[account] = bytes }
    }

    /// Replaces the bytes of an item (tampered or foreign DEK).
    public func replaceItem(account: String, with bytes: Data) {
        state.withLock { $0.items[account] = bytes }
    }

    /// Simulates an enrollment change: every later read throws `.biometryInvalidated`.
    public func invalidateItems() {
        state.withLock { $0.invalidated = true }
    }

    /// The next ``load(account:prompt:)`` throws `error` (one shot).
    public func failNextLoad(with error: VaultError) {
        state.withLock { $0.nextLoadError = error }
    }

    /// Runs `action` during the next ``load(account:prompt:)``, while the "prompt" is up (for
    /// example a lock arriving mid-prompt). One shot.
    public func onNextLoad(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.nextLoadAction = action }
    }

    /// Every later ``store(_:account:)`` throws `error`; nil restores success.
    public func failStores(with error: VaultError?) {
        state.withLock { $0.storeError = error }
    }

    // MARK: - Inspection

    /// Accounts with an item, sorted.
    public var accounts: [String] {
        state.withLock { $0.items.keys.sorted() }
    }

    /// The stored bytes of `account`, if any.
    public func storedBytes(account: String) -> Data? {
        state.withLock { $0.items[account] }
    }

    /// Number of ``load(account:prompt:)`` calls (each would be one Touch ID prompt).
    public var loadCount: Int {
        state.withLock { $0.loadCount }
    }

    /// Number of ``invalidateAuthentication()`` calls.
    public var invalidateCount: Int {
        state.withLock { $0.invalidateCount }
    }

    /// Accounts passed to ``delete(account:)``, in call order.
    public var deletedAccounts: [String] {
        state.withLock { $0.deletedAccounts }
    }

    /// The prompt of the last read.
    public var lastPrompt: BiometricPrompt? {
        state.withLock { $0.lastPrompt }
    }

    // MARK: - BiometricKeyStoring

    public func store(_ dek: SecretBytes, account: String) throws(VaultError) {
        let bytes = dek.withUnsafeBytes { Data($0) }
        let error: VaultError? = state.withLock { state in
            if let error = state.storeError { return error }
            state.items[account] = bytes
            state.invalidated = false
            return nil
        }
        if let error { throw error }
    }

    public func load(account: String, prompt: BiometricPrompt) throws(VaultError) -> SecretBytes {
        let action = state.withLock { state in
            let action = state.nextLoadAction
            state.nextLoadAction = nil
            return action
        }
        action?()
        let outcome: Result<Data, VaultError> = state.withLock { state in
            state.loadCount += 1
            state.lastPrompt = prompt
            if let error = state.nextLoadError {
                state.nextLoadError = nil
                return .failure(error)
            }
            guard !state.invalidated, let bytes = state.items[account] else {
                return .failure(.biometryInvalidated)
            }
            return .success(bytes)
        }
        var bytes = try outcome.get()
        return SecretBytes(wipingSource: &bytes)
    }

    public func contains(account: String) throws(VaultError) -> Bool {
        state.withLock { $0.items[account] != nil }
    }

    public func delete(account: String) throws(VaultError) {
        state.withLock { state in
            state.deletedAccounts.append(account)
            state.items[account] = nil
        }
    }

    public func allAccounts() throws(VaultError) -> [String] {
        accounts
    }

    public func invalidateAuthentication() {
        state.withLock { $0.invalidateCount += 1 }
    }
}
