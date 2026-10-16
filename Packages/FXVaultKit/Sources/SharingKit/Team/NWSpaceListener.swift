import Foundation
import Network
import VaultCore

/// A teammate's address outside the local network (v0.6.0, Q4): a host name or IP address and
/// a TCP port, typed by the user (for example a Tailscale name).
public struct TeamRemoteAddressModel: Sendable, Hashable {
    public let host: String
    public let port: UInt16

    /// Accepts `host:port` (an IPv6 address in brackets: `[::1]:port`). Host names are ASCII
    /// letters, digits, dots and hyphens; at most 253 characters.
    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmed.lastIndex(of: ":") else { return nil }
        var host = String(trimmed[..<separator])
        let portText = trimmed[trimmed.index(after: separator)...]
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
            guard IPv6Address(host) != nil else { return nil }
        } else {
            guard !host.isEmpty, host.utf8.count <= Self.maxHostBytes,
                  host.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "." || $0 == "-") }),
                  !host.hasPrefix("-"), !host.hasPrefix(".")
            else { return nil }
        }
        guard let port = UInt16(portText), port > 0 else { return nil }
        self.init(host: host, port: port)
    }

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// `host:port` (brackets around an IPv6 address).
    public var text: String {
        IPv6Address(host) != nil ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// The endpoint an outgoing spaces session connects to.
    public var endpoint: NearbyEndpointModel? {
        guard let port = NWEndpoint.Port(rawValue: port) else { return nil }
        return NearbyEndpointModel(id: text, endpoint: .hostPort(host: NWEndpoint.Host(host), port: port))
    }

    static let maxHostBytes = 253
}

/// When the remote space listener refuses everyone (Q4): ``Limits/remoteSpaceFailures`` failed
/// sessions within ``Timeouts/remoteSpaceBackoff`` close it for ``Timeouts/remoteSpaceBackoff``.
public struct RemoteSpaceBackoff: Sendable, Hashable {
    private var failures: [Date] = []
    private var closedUntil: Date?

    public init() {}

    public func isClosed(at now: Date) -> Bool {
        closedUntil.map { now < $0 } ?? false
    }

    /// Counts a failed session. Returns true when this one closes the listener.
    public mutating func recordFailure(at now: Date) -> Bool {
        let window = Timeouts.remoteSpaceBackoff.timeInterval
        failures = failures.filter { now.timeIntervalSince($0) < window } + [now]
        guard failures.count >= Limits.remoteSpaceFailures else { return false }
        failures = []
        closedUntil = now.addingTimeInterval(window)
        return true
    }
}

/// A connection the remote space listener accepted, before its preamble.
public struct RemoteSpaceConnectionModel: Sendable {
    public let transport: any NearbyTransport
    /// The peer's address as the connection reports it (shown in Members).
    public let source: String
}

/// Teammates' space sync from outside the local network (v0.6.0, Q4): a TCP listener on one
/// port, never advertised (no Bonjour), that only routes the spaces service. The app answers
/// each connection with the paired handshake for the teammates it allowed, so anything else is
/// closed before any space data; failed sessions are reported back for the backoff.
///
/// Queue-confined `@unchecked Sendable`: every mutable property is touched only on `queue`.
public final class NWSpaceListener: @unchecked Sendable {
    /// Accepted connections, not started. Finishes on ``stop()``.
    public let connections: AsyncStream<RemoteSpaceConnectionModel>
    /// Emits `.connectionFailed` when the port cannot be opened.
    public let failures: AsyncStream<NearbyTransportFailure>

    public let port: UInt16
    private let connectionsContinuation: AsyncStream<RemoteSpaceConnectionModel>.Continuation
    private let failuresContinuation: AsyncStream<NearbyTransportFailure>.Continuation
    private let queue = DispatchQueue(label: "io.fractalx.fxvault.space.listener")
    private var listener: NWListener?
    private var backoff = RemoteSpaceBackoff()
    private var acceptedTimes: [Date] = []
    private var isStopped = false

    public init(port: UInt16) {
        self.port = port
        (connections, connectionsContinuation) = AsyncStream.makeStream(of: RemoteSpaceConnectionModel.self)
        (failures, failuresContinuation) = AsyncStream.makeStream(of: NearbyTransportFailure.self)
    }

    public func start() {
        queue.async { [self] in
            open()
        }
    }

    /// Stops listening and finishes both streams. Idempotent.
    public func stop() {
        queue.async { [self] in
            guard !isStopped else { return }
            isStopped = true
            listener?.cancel()
            listener = nil
            connectionsContinuation.finish()
            failuresContinuation.finish()
        }
    }

    /// A session from this listener failed (handshake, a stranger, a refused teammate).
    public func recordFailedSession() {
        queue.async { [self] in
            let now = Date()
            guard backoff.recordFailure(at: now), !isStopped else { return }
            listener?.cancel()
            listener = nil
            queue.asyncAfter(deadline: .now() + Timeouts.remoteSpaceBackoff.timeInterval) { [weak self] in
                self?.open()
            }
        }
    }

    // MARK: - Queue-confined

    private func open() {
        guard !isStopped, listener == nil, !backoff.isClosed(at: Date()),
              let port = NWEndpoint.Port(rawValue: port)
        else { return }
        let next: NWListener
        do {
            next = try NWListener(using: Self.parameters(), on: port)
        } catch {
            failuresContinuation.yield(.connectionFailed)
            return
        }
        next.newConnectionHandler = { [weak self] connection in
            self?.received(connection)
        }
        next.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.failuresContinuation.yield(.connectionFailed) }
        }
        next.start(queue: queue)
        listener = next
    }

    private func received(_ connection: NWConnection) {
        let now = Date()
        acceptedTimes = acceptedTimes.filter { now.timeIntervalSince($0) < Double(Timeouts.secondsPerMinute) }
        guard !isStopped, !backoff.isClosed(at: now), acceptedTimes.count < Limits.teamConnectionsPerMinute else {
            connection.cancel()
            return
        }
        acceptedTimes.append(now)
        let source: String = switch connection.endpoint {
        case .hostPort(let host, _): "\(host)"
        default: ""
        }
        connectionsContinuation.yield(RemoteSpaceConnectionModel(transport: NWNearbyTransport.accepted(connection), source: source))
    }

    /// TCP on every interface but cellular, no peer-to-peer Wi-Fi, no Bonjour.
    static func parameters() -> NWParameters {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.includePeerToPeer = false
        return parameters
    }
}

extension Limits {
    /// Failed remote space sessions that close the listener (Q4).
    public static let remoteSpaceFailures = 5
}

extension Timeouts {
    /// The window failed remote sessions are counted in, and how long the listener then stays
    /// closed (Q4).
    public static let remoteSpaceBackoff: Duration = .seconds(10 * secondsPerMinute)
}

extension TeamProtocol {
    /// The port the remote space listener uses unless the user picks another (Q4).
    public static let defaultRemotePort: UInt16 = 52_731
}
