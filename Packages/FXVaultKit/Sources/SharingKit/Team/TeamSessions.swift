import Foundation
import VaultCore

/// Add Teammate over one ``NearbyTransport`` (T2): ``TeamPairingMachine`` with the nearby
/// timers (handshake ``Timeouts/nearbyHandshake``, code ``Timeouts/nearbySAS``, cards
/// ``Timeouts/nearbyIdle``). The responder waits for a connection without a timer. Runs once.
public actor TeamPairingSession {
    /// Events in order. Finishes when the pairing ends.
    public nonisolated let events: AsyncStream<TeamPairingEvent>
    public nonisolated let role: NearbyRole

    private let eventContinuation: AsyncStream<TeamPairingEvent>.Continuation
    private let runner: TeamFrameRunner
    private var machine: TeamPairingMachine
    private let clock: any VaultClock
    private var hasStarted = false
    private var isConnected = false
    private var timer: Task<Void, Never>?
    private var timerKind: NearbyTimeoutKind?

    public init(
        role: NearbyRole,
        localName: String,
        keys: TeamDeviceKeys,
        card: TeamCardModel,
        transport: any NearbyTransport,
        clock: any VaultClock = SystemClock()
    ) {
        self.init(
            machine: TeamPairingMachine(role: role, localName: localName, keys: keys, card: card),
            transport: transport,
            clock: clock
        )
    }

    init(machine: TeamPairingMachine, transport: any NearbyTransport, clock: any VaultClock) {
        self.machine = machine
        role = machine.role
        self.clock = clock
        runner = TeamFrameRunner(transport: transport)
        (events, eventContinuation) = AsyncStream.makeStream(of: TeamPairingEvent.self)
    }

    public var phase: TeamPairingPhase {
        machine.phase
    }

    /// Starts listening to the transport; the handshake starts once it connects.
    public func start() throws(ShareError) {
        guard !hasStarted else { throw .nearbySessionFinished }
        hasStarted = true
        runner.start { [weak self] event in
            await self?.handle(event)
        }
        if role == .initiator {
            restartTimer(.handshake)
        }
    }

    public func confirmSAS() throws(ShareError) {
        apply(try machine.confirmSAS())
    }

    public func rejectSAS() throws(ShareError) {
        apply(try machine.rejectSAS())
    }

    /// Cancels (an ABORT once the handshake started). Idempotent.
    public func cancel() {
        if !isConnected, !machine.phase.isTerminal {
            eventContinuation.yield(.aborted(NearbyAbortModel(reason: .cancelled, happenedAfterReveal: false)))
            shutDown()
            return
        }
        apply(machine.abort(.cancelled))
    }

    private func handle(_ event: NearbyTransportEvent) {
        guard !machine.phase.isTerminal else { return }
        switch event {
        case .connected:
            isConnected = true
            do {
                apply(try machine.start())
            } catch {
                apply(machine.abort(.unexpectedMessage))
            }
        case .received(let frame):
            apply(machine.receive(frame))
        case .disconnected, .failed:
            apply(machine.abort(.disconnected))
        case .secondPeer:
            apply(machine.abort(.secondPeer))
        }
    }

    private func apply(_ step: TeamPairingStep) {
        runner.send(step.frames)
        for event in step.events {
            eventContinuation.yield(event)
        }
        if machine.phase.isTerminal {
            shutDown()
        } else if machine.phase.timeoutKind != timerKind {
            restartTimer(machine.phase.timeoutKind)
        }
    }

    private func shutDown() {
        timer?.cancel()
        timer = nil
        runner.finish()
        eventContinuation.finish()
    }

    private func restartTimer(_ kind: NearbyTimeoutKind?) {
        timer?.cancel()
        timerKind = kind
        guard let kind else { return }
        let clock = clock
        timer = Task { [weak self] in
            do {
                try await clock.sleep(for: kind.duration)
            } catch {
                return
            }
            await self?.timerFired(kind)
        }
    }

    private func timerFired(_ kind: NearbyTimeoutKind) {
        guard kind == timerKind, !machine.phase.isTerminal else { return }
        apply(machine.abort(.timeout(kind)))
    }
}

/// What an initiator asks a teammate, in order, after the paired handshake.
public enum TeamRequest: Sendable, Hashable {
    /// "Your teammate pinged you" (T6).
    case ping
    /// This device's card with its new announce key.
    case updateCard(TeamCardModel)
}

/// One session between teammates over one ``NearbyTransport`` (T3, T6): the paired handshake,
/// then, for the initiator, its requests one after the other, then CLOSE. A team session must
/// finish within ``Timeouts/nearbyHandshake``. Runs once.
///
/// A spaces session (v0.6.0, S6) is pull-only: the initiator sends its heads, the responder
/// answers with its own, and the initiator fetches every version it lacks one at a time (a new
/// space's whole log first, verified as a whole) and hands them to its ``TeamSpaceExchanging``.
/// It must finish within ``Timeouts/spaceSyncSession``. A responder whose teammate is ahead pulls
/// in its own session afterwards (the app watches ``TeamSessionEvent/spaceHeadsRequested(_:_:)``).
public actor TeamSession {
    /// Events in order. Finishes when the session ends.
    public nonisolated let events: AsyncStream<TeamSessionEvent>
    public nonisolated let role: NearbyRole

    private let eventContinuation: AsyncStream<TeamSessionEvent>.Continuation
    private let runner: TeamFrameRunner
    private var machine: TeamSessionMachine
    private let clock: any VaultClock
    private var requests: [TeamRequest]
    private let exchanger: (any TeamSpaceExchanging)?
    private var hasStarted = false
    private var timer: Task<Void, Never>?

    /// I (spaces): one space still to fetch.
    private struct SpaceFetch {
        let spaceID: SpaceID
        var next: UInt64
        let last: UInt64
        /// This Mac has no version of it: the whole log is fetched, then stored at once.
        let isNew: Bool
        var batch: [Data] = []
        var bytes = 0
    }

    private var ownHeads: [SpaceHeadModel] = []
    private var fetches: [SpaceFetch] = []

    /// I: connects to `peer` and sends `requests` in order.
    public static func connect(
        to peer: TeamCardModel,
        keys: TeamDeviceKeys,
        requests: [TeamRequest],
        transport: any NearbyTransport,
        clock: any VaultClock = SystemClock()
    ) -> TeamSession {
        TeamSession(machine: .initiator(keys: keys, peer: peer), transport: transport, clock: clock, requests: requests)
    }

    /// I: connects to `peer` and pings it.
    public static func ping(
        _ peer: TeamCardModel,
        keys: TeamDeviceKeys,
        transport: any NearbyTransport,
        clock: any VaultClock = SystemClock()
    ) -> TeamSession {
        connect(to: peer, keys: keys, requests: [.ping], transport: transport, clock: clock)
    }

    /// I: syncs the spaces this Mac shares with `peer` (pulls what it lacks).
    public static func syncSpaces(
        with peer: TeamCardModel,
        keys: TeamDeviceKeys,
        exchanger: any TeamSpaceExchanging,
        transport: any NearbyTransport,
        clock: any VaultClock = SystemClock()
    ) -> TeamSession {
        TeamSession(
            machine: .initiator(keys: keys, peer: peer, service: .spaces),
            transport: transport,
            clock: clock,
            requests: [],
            exchanger: exchanger
        )
    }

    /// R: answers a connection the listener routed here (preamble `team`, or `spaces` with an
    /// `exchanger`).
    public static func answer(
        keys: TeamDeviceKeys,
        teammates: [TeamCardModel],
        transport: any NearbyTransport,
        clock: any VaultClock = SystemClock(),
        service: TeamService = .team,
        exchanger: (any TeamSpaceExchanging)? = nil
    ) -> TeamSession {
        TeamSession(
            machine: .responder(keys: keys, teammates: teammates, service: service),
            transport: transport,
            clock: clock,
            requests: [],
            exchanger: exchanger
        )
    }

    init(
        machine: TeamSessionMachine,
        transport: any NearbyTransport,
        clock: any VaultClock,
        requests: [TeamRequest],
        exchanger: (any TeamSpaceExchanging)? = nil
    ) {
        self.machine = machine
        role = machine.role
        self.clock = clock
        self.requests = requests
        self.exchanger = exchanger
        runner = TeamFrameRunner(transport: transport)
        (events, eventContinuation) = AsyncStream.makeStream(of: TeamSessionEvent.self)
    }

    public var phase: TeamSessionPhase {
        machine.phase
    }

    /// Starts the session and its time limit.
    public func start() throws(ShareError) {
        guard !hasStarted else { throw .nearbySessionFinished }
        hasStarted = true
        runner.start { [weak self] event in
            await self?.handle(event)
        }
        let clock = clock
        let limit = machine.service == .spaces ? Timeouts.spaceSyncSession : Timeouts.nearbyHandshake
        timer = Task { [weak self] in
            do {
                try await clock.sleep(for: limit)
            } catch {
                return
            }
            await self?.timedOut()
        }
    }

    public func cancel() {
        apply(machine.abort(.cancelled))
    }

    private func handle(_ event: NearbyTransportEvent) async {
        guard !machine.phase.isTerminal else { return }
        switch event {
        case .connected:
            do {
                apply(try machine.start())
            } catch {
                apply(machine.abort(.unexpectedMessage))
            }
        case .received(let frame):
            var step = machine.receive(frame)
            if machine.service == .spaces {
                await handleSpaces(step)
                return
            }
            if role == .initiator, machine.phase == .ready {
                step = merged(step, nextRequest())
            }
            apply(step)
        case .disconnected, .failed:
            apply(machine.abort(.disconnected))
        case .secondPeer:
            apply(machine.abort(.secondPeer))
        }
    }

    /// The next request, or CLOSE when none is left.
    private func nextRequest() -> TeamSessionStep {
        guard !requests.isEmpty else { return machine.close() }
        let request = requests.removeFirst()
        do {
            switch request {
            case .ping:
                return try machine.ping()
            case .updateCard(let card):
                return try machine.updateCard(card)
            }
        } catch {
            return machine.abort(.unexpectedMessage)
        }
    }

    // MARK: - Spaces (S6)

    private func handleSpaces(_ step: TeamSessionStep) async {
        guard let exchanger else {
            apply(merged(step, machine.abort(.unexpectedMessage)))
            return
        }
        switch role {
        case .responder:
            apply(step)
            for event in step.events {
                switch event {
                case .spaceHeadsRequested(let peer, _):
                    let heads = await exchanger.heads(sharedWith: peer.deviceID)
                    guard !machine.phase.isTerminal else { return }
                    apply(machine.answerSpaceHeads(Array(heads.prefix(SpaceProtocol.maxHeads))))
                case .spaceVersionRequested(let peer, let spaceID, let number):
                    let version = await exchanger.version(number, of: spaceID, for: peer.deviceID)
                    guard !machine.phase.isTerminal else { return }
                    apply(machine.answerSpaceVersion(version))
                default:
                    break
                }
            }
        case .initiator:
            guard machine.phase == .ready, let peer = machine.peer else {
                apply(step)
                return
            }
            var next = TeamSessionStep.none
            for event in step.events {
                switch event {
                case .authenticated:
                    ownHeads = await exchanger.heads(sharedWith: peer.deviceID)
                    do {
                        next = try machine.requestSpaceHeads(Array(ownHeads.prefix(SpaceProtocol.maxHeads)))
                    } catch {
                        next = machine.abort(.unexpectedMessage)
                    }
                    apply(merged(step, next))
                    return
                case .spaceHeadsAnswered(let theirs):
                    planFetches(theirs)
                case .spaceVersionAnswered(let version):
                    if let failure = await store(version, from: peer, exchanger: exchanger) {
                        apply(merged(step, machine.abort(failure)))
                        return
                    }
                default:
                    break
                }
            }
            guard !machine.phase.isTerminal else { return }
            if let fetch = fetches.first {
                do {
                    next = try machine.requestSpaceVersion(fetch.spaceID, version: fetch.next)
                } catch {
                    next = machine.abort(.unexpectedMessage)
                }
            } else {
                next = machine.close()
            }
            apply(merged(step, next))
        }
    }

    /// Every space the teammate holds versions of that this Mac lacks.
    private func planFetches(_ theirs: [SpaceHeadModel]) {
        let mine = Dictionary(ownHeads.map { ($0.spaceID, $0.version) }, uniquingKeysWith: { first, _ in first })
        fetches = theirs.compactMap { head in
            let have = mine[head.spaceID] ?? 0
            guard head.version > have else { return nil }
            return SpaceFetch(spaceID: head.spaceID, next: have + 1, last: head.version, isNew: have == 0)
        }
    }

    /// Hands a fetched version to the vault (a new space's log once it is complete) and moves on.
    /// Returns an abort reason when the log of a new space grows past its limit.
    private func store(_ version: Data?, from peer: TeamCardModel, exchanger: any TeamSpaceExchanging) async -> NearbyAbortReason? {
        guard var fetch = fetches.first else { return nil }
        guard let version else {
            fetches.removeFirst()
            return nil
        }
        if fetch.isNew {
            fetch.batch.append(version)
            fetch.bytes += version.count
            guard fetch.bytes <= SpaceProtocol.maxLogBytes else { return .payloadTooLarge }
            guard fetch.next == fetch.last else {
                fetch.next += 1
                fetches[0] = fetch
                return nil
            }
            _ = await exchanger.receive(fetch.batch, spaceID: fetch.spaceID, from: peer.deviceID)
            fetches.removeFirst()
            return nil
        }
        let stored = await exchanger.receive([version], spaceID: fetch.spaceID, from: peer.deviceID)
        if stored, fetch.next < fetch.last {
            fetch.next += 1
            fetches[0] = fetch
        } else {
            fetches.removeFirst()
        }
        return nil
    }

    private func merged(_ first: TeamSessionStep, _ second: TeamSessionStep) -> TeamSessionStep {
        TeamSessionStep(frames: first.frames + second.frames, events: first.events + second.events)
    }

    private func timedOut() {
        guard !machine.phase.isTerminal else { return }
        apply(machine.abort(.timeout(.handshake)))
    }

    private func apply(_ step: TeamSessionStep) {
        runner.send(step.frames)
        for event in step.events {
            eventContinuation.yield(event)
        }
        if machine.phase.isTerminal {
            timer?.cancel()
            timer = nil
            runner.finish()
            eventContinuation.finish()
        }
    }
}

/// Sends frames in order on one transport and delivers its events to a handler: the transport
/// plumbing both teammate sessions share. A failed send closes the transport, so the receiver
/// still handles what already arrived before the resulting `.disconnected`.
final class TeamFrameRunner: Sendable {
    private let transport: any NearbyTransport
    private let outbox: AsyncStream<Data>
    private let outboxContinuation: AsyncStream<Data>.Continuation

    init(transport: any NearbyTransport) {
        self.transport = transport
        (outbox, outboxContinuation) = AsyncStream.makeStream(of: Data.self)
    }

    func start(handler: @escaping @Sendable (NearbyTransportEvent) async -> Void) {
        let outbox = outbox
        let transport = transport
        Task {
            for await frame in outbox {
                do {
                    try await transport.send(frame)
                } catch {
                    break
                }
            }
            transport.close()
        }
        let events = transport.events
        Task {
            for await event in events {
                await handler(event)
            }
            await handler(.disconnected)
        }
    }

    func send(_ frames: [Data]) {
        for frame in frames {
            outboxContinuation.yield(frame)
        }
    }

    /// Drains the queued frames, then closes the transport.
    func finish() {
        outboxContinuation.finish()
    }
}

// MARK: - Routing

/// A connection the presence listener accepted, after its preamble: what it is for and a
/// transport whose events start with `.connected` and continue after the preamble.
public struct TeamIncomingConnectionModel: Sendable {
    public let service: TeamService
    public let transport: any NearbyTransport
}

/// Reads the preamble of a connection the presence listener accepted (T3) and hands the rest of
/// the connection on. A connection that sends anything else, or nothing within
/// ``Timeouts/nearbyHandshake``, is closed.
public enum TeamRouter {
    public static func route(
        _ transport: any NearbyTransport,
        clock: any VaultClock = SystemClock()
    ) async -> TeamIncomingConnectionModel? {
        let routed = RoutedTransport(base: transport)
        let timeout = Task {
            do {
                try await clock.sleep(for: Timeouts.nearbyHandshake)
            } catch {
                return
            }
            routed.giveUp()
        }
        let service = await routed.waitForPreamble()
        timeout.cancel()
        guard let service else {
            transport.close()
            return nil
        }
        return TeamIncomingConnectionModel(service: service, transport: routed)
    }
}

/// The far end of a routed connection: forwards the base transport's events after the preamble,
/// preceded by `.connected`.
final class RoutedTransport: NearbyTransport, @unchecked Sendable {
    let events: AsyncStream<NearbyTransportEvent>
    private let continuation: AsyncStream<NearbyTransportEvent>.Continuation
    private let base: any NearbyTransport
    private let lock = NSLock()
    private var preambleWaiter: CheckedContinuation<TeamService?, Never>?
    private var resolved: TeamService??

    init(base: any NearbyTransport) {
        self.base = base
        (events, continuation) = AsyncStream.makeStream(of: NearbyTransportEvent.self)
        let baseEvents = base.events
        Task { [weak self] in
            var routed = false
            for await event in baseEvents {
                guard let self else { return }
                if routed {
                    self.continuation.yield(event)
                    continue
                }
                switch event {
                case .connected, .secondPeer:
                    continue
                case .received(let frame):
                    let service = TeamService.decodePreamble(frame)
                    self.resolve(service)
                    guard service != nil else { return }
                    routed = true
                    self.continuation.yield(.connected)
                case .disconnected, .failed:
                    self.resolve(nil)
                    self.continuation.yield(event)
                    self.continuation.finish()
                    return
                }
            }
            self?.resolve(nil)
            self?.continuation.finish()
        }
    }

    func waitForPreamble() async -> TeamService? {
        await withCheckedContinuation { waiter in
            lock.lock()
            if let resolved {
                lock.unlock()
                waiter.resume(returning: resolved)
                return
            }
            preambleWaiter = waiter
            lock.unlock()
        }
    }

    /// No preamble in time: the router stops waiting.
    func giveUp() {
        resolve(nil)
    }

    private func resolve(_ service: TeamService?) {
        lock.lock()
        guard resolved == nil else {
            lock.unlock()
            return
        }
        resolved = .some(service)
        let waiter = preambleWaiter
        preambleWaiter = nil
        lock.unlock()
        waiter?.resume(returning: service)
    }

    func send(_ frame: Data) async throws(ShareError) {
        try await base.send(frame)
    }

    func close() {
        base.close()
        continuation.finish()
    }
}

/// An outgoing connection that sends `preamble` first, before the session sees `.connected`: a
/// chat started from a teammate's bubble reaches the teammate's presence listener (T7).
public final class PreambleTransport: NearbyTransport, @unchecked Sendable {
    public let events: AsyncStream<NearbyTransportEvent>
    private let base: any NearbyTransport

    public init(base: any NearbyTransport, service: TeamService) {
        self.base = base
        let (stream, continuation) = AsyncStream.makeStream(of: NearbyTransportEvent.self)
        events = stream
        let baseEvents = base.events
        let preamble = service.preamble
        Task {
            for await event in baseEvents {
                if case .connected = event {
                    do {
                        try await base.send(preamble)
                    } catch {
                        continuation.yield(.failed(.connectionFailed))
                        break
                    }
                }
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    public func send(_ frame: Data) async throws(ShareError) {
        try await base.send(frame)
    }

    public func close() {
        base.close()
    }
}

/// A transport that reports its first `.connected` to `onConnected` and forwards every event
/// unchanged: an advertisement kept by presence ("Everyone nearby") hands an incoming chat to
/// the chat window when someone connects (T4).
public final class WatchedTransport: NearbyTransport, @unchecked Sendable {
    public let events: AsyncStream<NearbyTransportEvent>
    private let base: any NearbyTransport

    public init(base: any NearbyTransport, onConnected: @escaping @Sendable () -> Void) {
        self.base = base
        let (stream, continuation) = AsyncStream.makeStream(of: NearbyTransportEvent.self)
        events = stream
        let baseEvents = base.events
        Task {
            var reported = false
            for await event in baseEvents {
                if case .connected = event, !reported {
                    reported = true
                    onConnected()
                }
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    public func send(_ frame: Data) async throws(ShareError) {
        try await base.send(frame)
    }

    public func close() {
        base.close()
    }
}
