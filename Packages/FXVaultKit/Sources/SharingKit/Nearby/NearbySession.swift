import Foundation
import VaultCore

/// Runs one ``NearbyHandshake`` over one ``NearbyTransport`` with the §9.4 timers.
///
/// - Frames are sent strictly in the order the state machine produced them (one sender task).
/// - Timers use the injected ``VaultClock``: the phase timer from ``NearbyPhase/timeoutKind``
///   (the idle timer restarts on every received frame) and the 10-minute session timer.
/// - Any abort or completion closes the transport, cancels the timers and finishes
///   ``events``. A session runs once: ``start()`` cannot be called again and nothing is
///   retried automatically (D21). A new attempt needs a new session and transport.
public actor NearbySession {
    /// UI events, in order. Finishes when the session ends.
    public nonisolated let events: AsyncStream<NearbyEvent>
    public nonisolated let role: NearbyRole

    private let eventContinuation: AsyncStream<NearbyEvent>.Continuation
    private let outbox: AsyncStream<Data>
    private let outboxContinuation: AsyncStream<Data>.Continuation
    private var handshake: NearbyHandshake
    private let transport: any NearbyTransport
    private let clock: any VaultClock
    private var hasStarted = false
    private var senderTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?
    private var sessionTimer: Task<Void, Never>?
    private var phaseTimer: Task<Void, Never>?
    private var phaseTimerKind: NearbyTimeoutKind?
    private var phaseTimerGeneration: UInt64 = 0

    public init(
        role: NearbyRole,
        localName: String,
        transport: any NearbyTransport,
        clock: any VaultClock = SystemClock()
    ) {
        self.init(
            handshake: NearbyHandshake(role: role, localName: localName),
            transport: transport,
            clock: clock
        )
    }

    /// Tests inject a handshake with fixed key material.
    init(handshake: NearbyHandshake, transport: any NearbyTransport, clock: any VaultClock) {
        self.handshake = handshake
        role = handshake.role
        self.transport = transport
        self.clock = clock
        (events, eventContinuation) = AsyncStream.makeStream(of: NearbyEvent.self)
        (outbox, outboxContinuation) = AsyncStream.makeStream(of: Data.self)
    }

    /// The current phase.
    public var phase: NearbyPhase {
        handshake.phase
    }

    /// The code and peer name once keys exist.
    public var sas: NearbySASModel? {
        handshake.sas
    }

    // MARK: - Actions

    /// Starts the session (I sends HELLO_I). Throws `.nearbySessionFinished` on a second call.
    public func start() throws(ShareError) {
        guard !hasStarted else { throw .nearbySessionFinished }
        hasStarted = true
        startSender()
        startReceiver()
        sessionTimer = makeTimer(.session) { session in await session.sessionTimerFired() }
        apply(try handshake.start())
    }

    /// "Codes match".
    public func confirmSAS() throws(ShareError) {
        apply(try handshake.confirmSAS())
    }

    /// "Don't match": aborts on both sides.
    public func rejectSAS() throws(ShareError) {
        apply(try handshake.rejectSAS())
    }

    /// I: sends the manifest. Call only after ReauthGate(.nearbySend) passed (D30).
    public func sendManifest(_ package: SharePackageModel) throws(ShareError) {
        apply(try handshake.sendManifest(package))
    }

    /// R: sends the decision.
    public func sendDecision(_ decision: NearbyDecisionModel) throws(ShareError) {
        apply(try handshake.sendDecision(decision))
    }

    /// I: sends the accepted part of `package`.
    public func sendPayload(_ package: SharePackageModel) throws(ShareError) {
        apply(try handshake.sendPayload(package))
    }

    /// R: sends the result.
    public func sendResult(ok: Bool) throws(ShareError) {
        apply(try handshake.sendResult(ok: ok))
    }

    /// Cancels the session (sheet closed, app locking). Idempotent.
    public func cancel() {
        apply(handshake.abort(.cancelled))
    }

    // MARK: - Transport

    private func startSender() {
        let outbox = outbox
        let transport = transport
        senderTask = Task { [weak self] in
            for await frame in outbox {
                do {
                    try await transport.send(frame)
                } catch {
                    await self?.transportFailed()
                    break
                }
            }
            transport.close()
        }
    }

    private func startReceiver() {
        let events = transport.events
        receiverTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
            await self?.handle(.disconnected)
        }
    }

    private func handle(_ event: NearbyTransportEvent) {
        guard !handshake.phase.isTerminal else { return }
        switch event {
        case .connected:
            return
        case .received(let frame):
            apply(handshake.receive(frame))
            if handshake.phase.timeoutKind == .idle {
                restartPhaseTimer(.idle)
            }
        case .disconnected, .failed:
            apply(handshake.abort(.disconnected))
        case .secondPeer:
            apply(handshake.abort(.secondPeer))
        }
    }

    private func transportFailed() {
        apply(handshake.abort(.disconnected))
    }

    // MARK: - Steps

    private func apply(_ step: NearbyStep) {
        for frame in step.frames {
            outboxContinuation.yield(frame)
        }
        for event in step.events {
            eventContinuation.yield(event)
        }
        if handshake.phase.isTerminal {
            shutDown()
        } else if handshake.phase.timeoutKind != phaseTimerKind {
            restartPhaseTimer(handshake.phase.timeoutKind)
        }
    }

    private func shutDown() {
        sessionTimer?.cancel()
        sessionTimer = nil
        phaseTimer?.cancel()
        phaseTimer = nil
        phaseTimerKind = nil
        receiverTask?.cancel()
        receiverTask = nil
        // The sender drains the remaining frames (for example ABORT), then closes.
        outboxContinuation.finish()
        eventContinuation.finish()
    }

    // MARK: - Timers

    private func restartPhaseTimer(_ kind: NearbyTimeoutKind?) {
        phaseTimer?.cancel()
        phaseTimer = nil
        phaseTimerKind = kind
        phaseTimerGeneration += 1
        guard let kind else { return }
        let generation = phaseTimerGeneration
        phaseTimer = makeTimer(kind) { session in
            await session.phaseTimerFired(kind, generation: generation)
        }
    }

    private func makeTimer(
        _ kind: NearbyTimeoutKind,
        fire: @escaping @Sendable (NearbySession) async -> Void
    ) -> Task<Void, Never> {
        let clock = clock
        return Task { [weak self] in
            do {
                try await clock.sleep(for: kind.duration)
            } catch {
                return
            }
            guard let self else { return }
            await fire(self)
        }
    }

    private func phaseTimerFired(_ kind: NearbyTimeoutKind, generation: UInt64) {
        guard generation == phaseTimerGeneration, !handshake.phase.isTerminal else { return }
        apply(handshake.abort(.timeout(kind)))
    }

    private func sessionTimerFired() {
        guard !handshake.phase.isTerminal else { return }
        apply(handshake.abort(.timeout(.session)))
    }
}
