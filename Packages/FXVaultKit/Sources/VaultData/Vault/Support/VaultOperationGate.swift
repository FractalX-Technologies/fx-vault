import os

/// Runs vault operations one at a time, in arrival order (unlock, password change, rotation,
/// Touch ID changes, re-authentication).
///
/// The operations suspend for Argon2id and Touch ID, so two of them could otherwise interleave
/// and, for example, store a password wrap for a DEK another operation just rotated away. ``lock()``
/// on ``VaultManager`` is deliberately **not** gated: it must stay synchronous.
final class VaultOperationGate: Sendable {
    private struct State: Sendable {
        var isBusy = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Waits for the gate, runs `body`, and opens the gate for the next waiter.
    func run<Result>(_ body: () async throws -> Result) async throws -> Result {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { state -> Bool in
                guard state.isBusy else {
                    state.isBusy = true
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if acquired {
                continuation.resume()
            }
        }
    }

    private func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.isBusy = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}
