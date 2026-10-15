import Foundation
import os
import VaultCore

/// The single-use core of every re-authentication proof (D30, §5.6): it is bound to the
/// session it was granted in and to that session's key generation, so a lock, unlock or key
/// rotation in between invalidates it, and it can be consumed once.
///
/// Each purpose wraps it in its own public type (``EnvExportAuthorizationModel``,
/// ``ShareAuthorizationModel``), so an authorization for one operation never unlocks another.
final class ReauthTicket: Sendable {
    private let sessionID: ObjectIdentifier
    private let generation: UInt64
    private let isConsumed = OSAllocatedUnfairLock(initialState: false)

    init(session: VaultSession) {
        sessionID = ObjectIdentifier(session)
        generation = session.generation
    }

    /// True until the ticket has been consumed.
    var isUsable: Bool {
        !isConsumed.withLock { $0 }
    }

    /// Consumes the ticket for `session`. Returns false (and consumes nothing) when it belongs
    /// to another session or the session's keys changed; false when it was already consumed.
    func consume(for session: VaultSession) -> Bool {
        guard ObjectIdentifier(session) == sessionID else { return false }
        do {
            try session.ensureCurrent(generation)
        } catch {
            return false
        }
        let wasConsumed = isConsumed.withLock { consumed in
            defer { consumed = true }
            return consumed
        }
        return !wasConsumed
    }
}
