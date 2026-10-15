import dnssd
import Foundation
import Network
import VaultCore

/// A nearby peer found by ``NWNearbyBrowser``. For share the instance name is random per
/// session and means nothing to the user; for chat it is the advertiser's display name
/// (unverified). The authenticated name and the code arrive in the handshake.
public struct NearbyEndpointModel: Sendable, Hashable, Identifiable {
    /// The Bonjour service instance name.
    public let id: String
    let endpoint: NWEndpoint

    init(id: String, endpoint: NWEndpoint) {
        self.id = id
        self.endpoint = endpoint
    }

    /// The instance name cleaned for display (control, bidi and zero-width characters removed,
    /// at most ``Limits/maxDisplayNameBytes``). Unverified: anyone can advertise any name.
    public var displayName: String {
        DisplayNameSanitizer.sanitize(id)
    }
}

/// Shared Network framework settings for nearby share and chat (D22, §9.4).
enum NWNearbyConfiguration {
    /// Prefix of the random service instance name.
    static let instanceNamePrefix = "FXVault-"
    /// Random bytes in the instance name (hex encoded).
    static let instanceNameRandomBytes = 8
    /// Largest read requested from the connection at once.
    static let readChunkBytes = NearbyProtocol.maxTransportFrameBytes + NearbyLengthFramer.prefixBytes

    /// TCP, local network only (`acceptLocalOnly`), cellular prohibited, peer-to-peer Wi-Fi
    /// allowed. `includePeerToPeer` lets Bonjour and TCP run over AWDL, as AirDrop does, so two
    /// Macs with Wi-Fi turned on find each other without sharing a network or a router. The same
    /// parameters serve the listener, the browser and the outgoing connection.
    static func parameters() -> NWParameters {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.acceptLocalOnly = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.includePeerToPeer = true
        return parameters
    }

    /// The Bonjour domain for browsing and advertising: link-local multicast DNS only
    /// (infrastructure Wi-Fi or Ethernet, and peer-to-peer Wi-Fi), never a wide-area DNS-SD
    /// domain a network may publish, where a chat advertiser's display name would leak.
    static let bonjourDomain = "local."

    /// The TXT record advertised by receivers: only `v=1`.
    static func txtRecord() -> NWTXTRecord {
        NWTXTRecord([NearbyProtocol.txtVersionKey: NearbyProtocol.txtVersionValue])
    }

    /// The instance name a chat advertiser publishes: its sanitized display name (Bonjour
    /// allows 63 bytes, the display-name limit), or a random name when nothing is left.
    static func chatInstanceName(displayName: String) -> String {
        let name = DisplayNameSanitizer.sanitize(displayName)
        return name.isEmpty ? randomInstanceName() : name
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

/// Browses for peers advertising the purpose's service type (`_fxvault-share._tcp` or
/// `_fxvault-chat._tcp`) with `v=1` (I side), on the local network and over peer-to-peer Wi-Fi.
///
/// Queue-confined `@unchecked Sendable`: every mutable property is touched only on `queue`.
public final class NWNearbyBrowser: @unchecked Sendable {
    /// What this browser looks for.
    public let purpose: NearbyPurpose
    /// The current receivers, sorted by instance name. Finishes on ``stop()`` or failure.
    public let results: AsyncStream<[NearbyEndpointModel]>
    /// Emits `.localNetworkDenied` or `.connectionFailed` if browsing fails, then finishes.
    public let failures: AsyncStream<NearbyTransportFailure>

    private let resultsContinuation: AsyncStream<[NearbyEndpointModel]>.Continuation
    private let failuresContinuation: AsyncStream<NearbyTransportFailure>.Continuation
    private let queue = DispatchQueue(label: "io.fractalx.fxvault.nearby.browser")
    private var browser: NWBrowser?

    public init(purpose: NearbyPurpose = .share) {
        self.purpose = purpose
        (results, resultsContinuation) = AsyncStream.makeStream(of: [NearbyEndpointModel].self)
        (failures, failuresContinuation) = AsyncStream.makeStream(of: NearbyTransportFailure.self)
    }

    /// Starts browsing. Calling it twice has no effect.
    public func start() {
        queue.async { [self] in
            guard browser == nil else { return }
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
                type: purpose.bonjourServiceType,
                domain: NWNearbyConfiguration.bonjourDomain
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
/// framing, one connection per session, over the local network or peer-to-peer Wi-Fi (AWDL).
///
/// - Receiver (R): ``advertising(purpose:)`` publishes the purpose's service type under a random
///   instance name (share) or ``advertisingChat(displayName:)`` under the display name (chat),
///   with TXT `v=1`, accepts the first connection, then closes the listener. Any further
///   connection attempt is refused and reported as `.secondPeer`.
/// - Sender (I): ``connecting(to:)`` opens one connection to a browsed endpoint.
///
/// Queue-confined `@unchecked Sendable`: every mutable property is touched only on `queue`.
public final class NWNearbyTransport: NearbyTransport, @unchecked Sendable {
    public let events: AsyncStream<NearbyTransportEvent>
    /// The advertised instance name (receiver only).
    public let serviceName: String?
    /// The purpose whose service type is advertised (receiver only; nil for a sender).
    public let purpose: NearbyPurpose?
    /// The instance name the system actually registered (receiver only). Bonjour renames on a
    /// conflict ("Bob's Mac (2)"), so this can differ from ``serviceName``. Finishes with the
    /// transport.
    public let registeredServiceNames: AsyncStream<String>

    private let continuation: AsyncStream<NearbyTransportEvent>.Continuation
    private let registeredNamesContinuation: AsyncStream<String>.Continuation
    private let queue = DispatchQueue(label: "io.fractalx.fxvault.nearby.transport")
    private let target: NearbyEndpointModel?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var framer = NearbyLengthFramer()
    private var hasAcceptedPeer = false
    private var isStarted = false
    private var isClosed = false

    private init(serviceName: String?, purpose: NearbyPurpose?, target: NearbyEndpointModel?) {
        self.serviceName = serviceName
        self.purpose = purpose
        self.target = target
        (events, continuation) = AsyncStream.makeStream(of: NearbyTransportEvent.self)
        (registeredServiceNames, registeredNamesContinuation) = AsyncStream.makeStream(of: String.self)
        if target != nil {
            registeredNamesContinuation.finish()
        }
    }

    /// A receiver transport with a fresh random instance name. Call ``start()``.
    public static func advertising(purpose: NearbyPurpose = .share) -> NWNearbyTransport {
        NWNearbyTransport(
            serviceName: NWNearbyConfiguration.randomInstanceName(),
            purpose: purpose,
            target: nil
        )
    }

    /// A chat receiver advertised under `displayName` (sanitized; random if nothing is left),
    /// so nearby Macs can tell who is available while the chat window is open. The name is
    /// unverified; only the code authenticates the peer. Call ``start()``.
    public static func advertisingChat(displayName: String) -> NWNearbyTransport {
        NWNearbyTransport(
            serviceName: NWNearbyConfiguration.chatInstanceName(displayName: displayName),
            purpose: .chat,
            target: nil
        )
    }

    /// A sender transport to `endpoint` (found by a browser of either purpose). Call ``start()``.
    public static func connecting(to endpoint: NearbyEndpointModel) -> NWNearbyTransport {
        NWNearbyTransport(serviceName: nil, purpose: nil, target: endpoint)
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
        guard let serviceName, let purpose else { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: NWNearbyConfiguration.parameters())
        } catch {
            finish(with: .failed(.connectionFailed))
            return
        }
        listener.service = NWListener.Service(
            name: serviceName,
            type: purpose.bonjourServiceType,
            domain: NWNearbyConfiguration.bonjourDomain,
            txtRecord: NWNearbyConfiguration.txtRecord()
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.listenerReceived(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.listenerChanged(state)
        }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            self?.registrationChanged(change)
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

    private func registrationChanged(_ change: NWListener.ServiceRegistrationChange) {
        guard !isClosed, case .add(let endpoint) = change, case .service(let name, _, _, _) = endpoint else { return }
        registeredNamesContinuation.yield(name)
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
        registeredNamesContinuation.finish()
    }

    private static func failure(from error: ShareError) -> NearbyTransportFailure {
        if case .transport(let failure) = error { return failure }
        return .malformedFrame
    }
}
