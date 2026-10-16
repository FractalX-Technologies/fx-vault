import Foundation
import Network
import VaultCore

/// The presence advertisement of a Mac visible to its teammates (T3, T8): `_fxvault-team._tcp`
/// under this device's current pseudonym, re-registered under the next one at every window
/// change, accepting any number of connections one by one. Each accepted connection is handed
/// out as a transport; ``TeamRouter`` then reads its preamble.
///
/// Limits: at most ``Limits/teamConnectionsPerMinute`` connections per minute are accepted;
/// more are refused at once, so a stranger cannot flood the app. Link-local Bonjour only,
/// TCP, local network and peer-to-peer Wi-Fi (``NWNearbyConfiguration/parameters()``).
///
/// Queue-confined `@unchecked Sendable`: every mutable property is touched only on `queue`.
public final class NWTeamListener: @unchecked Sendable {
    /// Accepted connections, not started. Finishes on ``stop()``.
    public let connections: AsyncStream<any NearbyTransport>
    /// Emits `.localNetworkDenied` or `.connectionFailed` if advertising fails.
    public let failures: AsyncStream<NearbyTransportFailure>

    private let connectionsContinuation: AsyncStream<any NearbyTransport>.Continuation
    private let failuresContinuation: AsyncStream<NearbyTransportFailure>.Continuation
    private let queue = DispatchQueue(label: "io.fractalx.fxvault.team.listener")
    private var listener: NWListener?
    private var serviceName: String?
    private var acceptedTimes: [Date] = []
    private var isStopped = false

    public init() {
        (connections, connectionsContinuation) = AsyncStream.makeStream(of: (any NearbyTransport).self)
        (failures, failuresContinuation) = AsyncStream.makeStream(of: NearbyTransportFailure.self)
    }

    /// Advertises under `serviceName` (a pseudonym), replacing the current advertisement. The
    /// new listener starts before the old one is cancelled, so nobody sees a gap.
    public func advertise(as serviceName: String) {
        queue.async { [self] in
            guard !isStopped, serviceName != self.serviceName else { return }
            let next: NWListener
            do {
                next = try NWListener(using: NWNearbyConfiguration.parameters())
            } catch {
                failuresContinuation.yield(.connectionFailed)
                return
            }
            next.service = NWListener.Service(
                name: serviceName,
                type: TeamProtocol.presenceServiceType,
                domain: NWNearbyConfiguration.bonjourDomain,
                txtRecord: NWNearbyConfiguration.txtRecord()
            )
            next.newConnectionHandler = { [weak self] connection in
                self?.received(connection)
            }
            next.stateUpdateHandler = { [weak self] state in
                self?.listenerChanged(state)
            }
            next.start(queue: queue)
            listener?.cancel()
            listener = next
            self.serviceName = serviceName
        }
    }

    /// Stops advertising and finishes both streams. Idempotent.
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

    // MARK: - Queue-confined

    private func received(_ connection: NWConnection) {
        let now = Date()
        acceptedTimes = acceptedTimes.filter { now.timeIntervalSince($0) < Double(Timeouts.secondsPerMinute) }
        guard !isStopped, acceptedTimes.count < Limits.teamConnectionsPerMinute else {
            connection.cancel()
            return
        }
        acceptedTimes.append(now)
        connectionsContinuation.yield(NWNearbyTransport.accepted(connection))
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .failed(let error), .waiting(let error):
            let isDenied = NWNearbyConfiguration.isLocalNetworkDenial(error)
            if case .waiting = state, !isDenied { return }
            failuresContinuation.yield(isDenied ? .localNetworkDenied : .connectionFailed)
        default:
            break
        }
    }
}

extension Limits {
    /// Connections the presence listener accepts per minute (v0.5.0); more are refused.
    public static let teamConnectionsPerMinute = 20
}
