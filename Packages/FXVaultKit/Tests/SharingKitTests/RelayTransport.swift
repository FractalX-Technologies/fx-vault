import Foundation
import os
@testable import SharingKit

/// Test double for an on-path relay (MITM): the initiator talks to one in-memory pair, the
/// responder to another, and every frame passes through `intercept`, which may forward,
/// rewrite, drop, duplicate or reorder frames.
final class RelayTransport: Sendable {
    enum Direction: Sendable {
        case toResponder
        case toInitiator
    }

    /// Give this to the initiator's session.
    var initiatorTransport: InMemoryTransport { initiatorSide.initiator }
    /// Give this to the responder's session.
    var responderTransport: InMemoryTransport { responderSide.responder }

    private let initiatorSide = InMemoryTransportPair()
    private let responderSide = InMemoryTransportPair()
    private let intercept: @Sendable (Direction, Data) -> [Data]
    private let tasks = OSAllocatedUnfairLock(initialState: [Task<Void, Never>]())

    init(intercept: @escaping @Sendable (Direction, Data) -> [Data] = { [$1] }) {
        self.intercept = intercept
    }

    /// Starts forwarding in both directions.
    func start() {
        let toResponder = forward(
            from: initiatorSide.responder,
            to: responderSide.initiator,
            direction: .toResponder
        )
        let toInitiator = forward(
            from: responderSide.initiator,
            to: initiatorSide.responder,
            direction: .toInitiator
        )
        tasks.withLock { $0 = [toResponder, toInitiator] }
    }

    private func forward(
        from source: InMemoryTransport,
        to destination: InMemoryTransport,
        direction: Direction
    ) -> Task<Void, Never> {
        let intercept = intercept
        return Task {
            for await event in source.events {
                switch event {
                case .received(let frame):
                    for output in intercept(direction, frame) {
                        try? await destination.send(output)
                    }
                case .disconnected:
                    destination.close()
                    return
                default:
                    break
                }
            }
        }
    }
}
