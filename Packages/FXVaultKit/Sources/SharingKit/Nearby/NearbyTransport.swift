import Foundation
import os
import VaultCore

/// Something that happened on a nearby transport.
public enum NearbyTransportEvent: Sendable, Equatable {
    /// The single peer connection is ready.
    case connected
    /// One complete frame from the peer (length framing already removed).
    case received(Data)
    /// The peer went away or the transport was closed.
    case disconnected
    /// Another peer tried to connect while a session was active (an abort condition, §9.4).
    case secondPeer
    /// The transport failed; the session aborts.
    case failed(NearbyTransportFailure)
}

/// Transport-level failures. Carry no peer data.
public enum NearbyTransportFailure: Sendable, Hashable {
    /// `send` was called before a connection existed.
    case notConnected
    /// The transport is closed.
    case closed
    /// A length prefix exceeded ``NearbyProtocol/maxTransportFrameBytes``.
    case oversizeFrame
    /// A zero-length frame or a broken stream.
    case malformedFrame
    /// The connection, listener or browser failed.
    case connectionFailed
    /// macOS Local Network privacy denied access; the UI shows guidance for System Settings.
    case localNetworkDenied
}

/// A reliable, ordered, single-peer frame pipe for ``NearbySession`` (§4.3, D22).
///
/// Implementations are queue-confined or lock-protected `Sendable` types: only `Data`, enums
/// and strings cross isolation boundaries. One transport carries one session; it is never
/// reused or reconnected (no automatic retry).
public protocol NearbyTransport: Sendable {
    /// Events in arrival order. Finishes after `.disconnected` or `.failed`.
    var events: AsyncStream<NearbyTransportEvent> { get }
    /// Sends one frame. Frames sent by one caller arrive in order.
    func send(_ frame: Data) async throws(ShareError)
    /// Closes the connection; the peer sees `.disconnected`. Idempotent.
    func close()
}

/// One end of an ``InMemoryTransportPair``: delivers frames straight to the other end.
/// Used by tests and previews; never touches the network.
public final class InMemoryTransport: NearbyTransport, Sendable {
    public let events: AsyncStream<NearbyTransportEvent>
    private let continuation: AsyncStream<NearbyTransportEvent>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State: Sendable {
        weak var peer: InMemoryTransport?
        var isClosed = false
        var sentFrames: [Data] = []
    }

    init() {
        (events, continuation) = AsyncStream.makeStream(of: NearbyTransportEvent.self)
    }

    /// Every frame this end sent, in order (for tests).
    public var sentFrames: [Data] {
        state.withLock { $0.sentFrames }
    }

    public func send(_ frame: Data) async throws(ShareError) {
        let (isClosed, peer) = state.withLock { state -> (Bool, InMemoryTransport?) in
            guard !state.isClosed else { return (true, nil) }
            state.sentFrames.append(frame)
            return (false, state.peer)
        }
        guard !isClosed else { throw .transport(.closed) }
        guard let peer else { throw .transport(.notConnected) }
        peer.deliver(.received(frame))
    }

    public func close() {
        let peer: InMemoryTransport? = state.withLock { state in
            guard !state.isClosed else { return nil }
            state.isClosed = true
            return state.peer
        }
        continuation.yield(.disconnected)
        continuation.finish()
        peer?.peerClosed()
    }

    /// Injects an event as if it came from the network (tests: second peer, failures).
    public func inject(_ event: NearbyTransportEvent) {
        deliver(event)
    }

    fileprivate func connect(to peer: InMemoryTransport) {
        state.withLock { $0.peer = peer }
        continuation.yield(.connected)
    }

    private func deliver(_ event: NearbyTransportEvent) {
        let isClosed = state.withLock { $0.isClosed }
        guard !isClosed else { return }
        continuation.yield(event)
    }

    private func peerClosed() {
        let wasOpen = state.withLock { state -> Bool in
            defer { state.isClosed = true }
            return !state.isClosed
        }
        guard wasOpen else { return }
        continuation.yield(.disconnected)
        continuation.finish()
    }
}

/// Two connected in-memory transports: `initiator` and `responder`.
public struct InMemoryTransportPair: Sendable {
    public let initiator: InMemoryTransport
    public let responder: InMemoryTransport

    public init() {
        initiator = InMemoryTransport()
        responder = InMemoryTransport()
        initiator.connect(to: responder)
        responder.connect(to: initiator)
    }
}
