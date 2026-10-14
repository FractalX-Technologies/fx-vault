import dnssd
import Foundation
import Network
import VaultCore

/// A nearby receiver found by ``NWNearbyBrowser``. The instance name is random per session
/// and means nothing to the user; the peer's display name arrives in HELLO_R.
public struct NearbyEndpointModel: Sendable, Hashable, Identifiable {
    /// The Bonjour service instance name.
    public let id: String
    let endpoint: NWEndpoint

    init(id: String, endpoint: NWEndpoint) {
        self.id = id
        self.endpoint = endpoint
    }
}

/// Shared Network framework settings for nearby sharing (D22, §9.4).
enum NWNearbyConfiguration {
    /// Prefix of the random service instance name.
    static let instanceNamePrefix = "FXVault-"
    /// Random bytes in the instance name (hex encoded).
    static let instanceNameRandomBytes = 8
    /// Largest read requested from the connection at once.
    static let readChunkBytes = NearbyProtocol.maxTransportFrameBytes + NearbyLengthFramer.prefixBytes

    /// TCP, local network only (`acceptLocalOnly`), cellular prohibited, no peer-to-peer Wi-Fi.
    static func parameters() -> NWParameters {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.acceptLocalOnly = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.includePeerToPeer = false
        return parameters
    }

    /// The TXT record advertised by receivers: only `v=1`.
    static func txtRecord() -> NWTXTRecord {
        NWTXTRecord([NearbyProtocol.txtVersionKey: NearbyProtocol.txtVersionValue])
    }

    /// A new random instance name for one session.
    static func randomInstanceName() -> String {
        var generator = SystemRandomNumberGenerator()
        let suffix = (0..<instanceNameRandomBytes)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
        return instanceNamePrefix + suffix
    }

    /// Whether a waiting/failed error is a Local Network privacy denial.
    static func isLocalNetworkDenial(_ error: NWError) -> Bool {
        if case .dns(let code) = error {
            return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
        }
        return false
    }
}

/// Browses for receivers advertising `_fxvault-share._tcp` with `v=1` (I side).
///
/// Queue-confined `@unchecked Sendable`: every mutable property is touched only on `queue`.
public final class NWNearbyBrowser: @unchecked Sendable {
    /// The current receivers, sorted by instance name. Finishes on ``stop()`` or failure.
    public let results: AsyncStream<[NearbyEndpointModel]>
    /// Emits `.localNetworkDenied` or `.connectionFailed` if browsing fails, then finishes.
    public let failures: AsyncStream<NearbyTransportFailure>

    private let resultsContinuation: AsyncStream<[NearbyEndpointModel]>.Continuation
    private let failuresContinuation: AsyncStream<NearbyTransportFailure>.Continuation
    private let queue = DispatchQueue(label: "io.fractalx.fxvault.nearby.browser")
    private var browser: NWBrowser?

    public init() {
        (results, resultsContinuation) = AsyncStream.makeStream(of: [NearbyEndpointModel].self)
        (failures, failuresContinuation) = AsyncStream.makeStream(of: NearbyTransportFailure.self)
    }

    /// Starts browsing. Calling it twice has no effect.
    public func start() {
        queue.async { [self] in
            guard browser == nil else { return }
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
                type: NearbyProtocol.bonjourServiceType,
                domain: nil
            )
            let browser = NWBrowser(for: descriptor, using: NWNearbyConfiguration.parameters())
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.publish(results)
            }
            browser.stateUpdateHandler = { [weak self] state in
                self?.handle(state)
            }
            self.browser = browser
            browser.start(queue: queue)
        }
    }

    /// Stops browsing and finishes both streams. Idempotent.
    public func stop() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
            resultsContinuation.finish()
            failuresContinuation.finish()
        }
    }

    private func publish(_ results: Set<NWBrowser.Result>) {
        let endpoints = results.compactMap { result -> NearbyEndpointModel? in
            guard case .service(let name, _, _, _) = result.endpoint,
                  case .bonjour(let record) = result.metadata,
                  record[NearbyProtocol.txtVersionKey] == NearbyProtocol.txtVersionValue
            else { return nil }
            return NearbyEndpointModel(id: name, endpoint: result.endpoint)
        }
        resultsContinuation.yield(endpoints.sorted { $0.id < $1.id })
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .failed(let error), .waiting(let error):
            let failure: NearbyTransportFailure = NWNearbyConfiguration.isLocalNetworkDenial(error)
                ? .localNetworkDenied
                : .connectionFailed
            if case .waiting = state, failure != .localNetworkDenied { return }
            failuresContinuation.yield(failure)
            stop()
        default:
            break
        }
    }
}

/// The Network framework ``NearbyTransport`` (D22, §9.4): TCP with 4-byte big-endian length
/// framing, one connection per session.
///
/// - Receiver (R): ``advertising()`` publishes `_fxvault-share._tcp` under a random instance
///   name with TXT `v=1`, accepts the first connection, then closes the listener. Any further
///   connection attempt is refused and reported as `.secondPeer`.
/// - Sender (I): ``connecting(to:)`` opens one connection to a browsed endpoint.
///
/// Queue-confined `@unchecked Sendable`: every mutable property is touched only on `queue`.
public final class NWNearbyTransport: NearbyTransport, @unchecked Sendable {
    public let events: AsyncStream<NearbyTransportEvent>
    /// The advertised instance name (receiver only).
    public let serviceName: String?

    private let continuation: AsyncStream<NearbyTransportEvent>.Continuation
    private let queue = DispatchQueue(label: "io.fractalx.fxvault.nearby.transport")
    private let target: NearbyEndpointModel?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var framer = NearbyLengthFramer()
    private var hasAcceptedPeer = false
    private var isStarted = false
    private var isClosed = false

    private init(serviceName: String?, target: NearbyEndpointModel?) {
        self.serviceName = serviceName
        self.target = target
        (events, continuation) = AsyncStream.makeStream(of: NearbyTransportEvent.self)
    }

    /// A receiver transport with a fresh random instance name. Call ``start()``.
    public static func advertising() -> NWNearbyTransport {
        NWNearbyTransport(serviceName: NWNearbyConfiguration.randomInstanceName(), target: nil)
    }

    /// A sender transport to `endpoint`. Call ``start()``.
    public static func connecting(to endpoint: NearbyEndpointModel) -> NWNearbyTransport {
        NWNearbyTransport(serviceName: nil, target: endpoint)
    }

    /// Starts listening (receiver) or connecting (sender). Runs once.
    public func start() {
        queue.async { [self] in
            guard !isStarted, !isClosed else { return }
            isStarted = true
            if let target {
                accept(NWConnection(to: target.endpoint, using: NWNearbyConfiguration.parameters()))
            } else {
                startListener()
            }
        }
    }

    public func send(_ frame: Data) async throws(ShareError) {
        // A fresh framer: `framer` is queue-confined and must not be read here.
        let framed = try NearbyLengthFramer().encode(frame)
        let failure: NearbyTransportFailure? = await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !isClosed else {
                    continuation.resume(returning: .closed)
                    return
                }
                guard let connection else {
                    continuation.resume(returning: .notConnected)
                    return
                }
                connection.send(content: framed, completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil ? nil : .connectionFailed)
                })
            }
        }
        if let failure { throw .transport(failure) }
    }

    public func close() {
        queue.async { [self] in
            finish(with: .disconnected)
        }
    }

    // MARK: - Queue-confined

    private func startListener() {
        guard let serviceName else { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: NWNearbyConfiguration.parameters())
        } catch {
            finish(with: .failed(.connectionFailed))
            return
        }
        listener.service = NWListener.Service(
            name: serviceName,
            type: NearbyProtocol.bonjourServiceType,
            domain: nil,
            txtRecord: NWNearbyConfiguration.txtRecord()
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.listenerReceived(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.listenerChanged(state)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func listenerReceived(_ newConnection: NWConnection) {
        guard !hasAcceptedPeer, !isClosed else {
            newConnection.cancel()
            if !isClosed {
                continuation.yield(.secondPeer)
            }
            return
        }
        hasAcceptedPeer = true
        listener?.cancel()
        listener = nil
        accept(newConnection)
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .failed(let error), .waiting(let error):
            guard !hasAcceptedPeer else { return }
            let isDenied = NWNearbyConfiguration.isLocalNetworkDenial(error)
            if case .waiting = state, !isDenied { return }
            finish(with: .failed(isDenied ? .localNetworkDenied : .connectionFailed))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.connectionChanged(state)
        }
        connection.start(queue: queue)
    }

    private func connectionChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            continuation.yield(.connected)
            receiveNext()
        case .waiting(let error):
            if NWNearbyConfiguration.isLocalNetworkDenial(error) {
                finish(with: .failed(.localNetworkDenied))
            }
        case .failed:
            finish(with: .failed(.connectionFailed))
        case .cancelled:
            finish(with: .disconnected)
        default:
            break
        }
    }

    private func receiveNext() {
        guard let connection, !isClosed else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: NWNearbyConfiguration.readChunkBytes
        ) { [weak self] content, _, isComplete, error in
            self?.received(content, isComplete: isComplete, error: error)
        }
    }

    private func received(_ content: Data?, isComplete: Bool, error: NWError?) {
        guard !isClosed else { return }
        if let content, !content.isEmpty {
            do {
                for frame in try framer.append(content) {
                    continuation.yield(.received(frame))
                }
            } catch {
                finish(with: .failed(Self.failure(from: error)))
                return
            }
        }
        if error != nil {
            finish(with: .failed(.connectionFailed))
        } else if isComplete {
            finish(with: .disconnected)
        } else {
            receiveNext()
        }
    }

    private func finish(with event: NearbyTransportEvent) {
        guard !isClosed else { return }
        isClosed = true
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        continuation.yield(event)
        continuation.finish()
    }

    private static func failure(from error: ShareError) -> NearbyTransportFailure {
        if case .transport(let failure) = error { return failure }
        return .malformedFrame
    }
}
