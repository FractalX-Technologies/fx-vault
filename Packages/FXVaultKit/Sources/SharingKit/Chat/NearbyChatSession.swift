import Foundation
import VaultCore

/// One ephemeral, end-to-end encrypted 1:1 chat over one ``NearbyTransport``
/// (`fxvault-chat/v1`, docs/SHARING-PROTOCOL.md "Nearby chat").
///
/// - Handshake: the share handshake with the chat labels (purpose `.chat`). The responder waits
///   for the transport to connect without a timer; then HELLO through REVEAL must finish within
///   ``Timeouts/nearbyHandshake`` and the codes must be confirmed within ``Timeouts/nearbySAS``.
/// - Chatting: TEXT, attachments, PING every ``Timeouts/chatKeepaliveInterval`` (the chat aborts
///   with `.timeout(.keepalive)` once ``Limits/chatMaxUnansweredPings`` PINGs are unanswered),
///   and `.timeout(.chatIdle)` after ``Timeouts/chatIdle`` without a message or attachment frame.
/// - Ephemeral: messages exist only in the delivered events; nothing is written to disk.
///   ``close()``, an abort and a disconnect wipe the keys, every offer, every value provider and
///   any partial payload. The app closes the chat when the window closes or the vault locks.
/// - Attachments: ``offerAttachment(manifest:payloadProvider:)`` sends names only; the provider
///   is called only when the peer requests the value, and the session wipes what it returns.
///   The app must pass ReauthGate before offering. A received payload arrives as
///   `.attachmentReceived` with ``SecretBytes`` values: the app previews and merges it through
///   the share import planner, re-encrypts it into the vault and wipes it.
///
/// A session runs once: ``start()`` cannot be called again and nothing is retried.
public actor NearbyChatSession {
    /// UI events, in order. Finishes when the chat ends.
    public nonisolated let events: AsyncStream<NearbyChatEvent>
    public nonisolated let role: NearbyRole

    private let eventContinuation: AsyncStream<NearbyChatEvent>.Continuation
    private let outbox: AsyncStream<Data>
    private let outboxContinuation: AsyncStream<Data>.Continuation
    private var machine: NearbyChatMachine
    private let transport: any NearbyTransport
    private let clock: any VaultClock
    private var hasStarted = false
    private var providers: [ChatAttachmentID: PayloadProvider] = [:]
    private var providerTasks: [ChatAttachmentID: Task<Void, Never>] = [:]
    private var senderTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var phaseTimer: Task<Void, Never>?
    private var phaseTimerKind: NearbyTimeoutKind?
    private var phaseTimerGeneration: UInt64 = 0

    /// - Parameters:
    ///   - role: `.initiator` browses and connects; `.responder` advertises.
    ///   - localName: this Mac's display name; sanitized before sending.
    ///   - team: this Mac's teammate keys and teammates (v0.5.0), so a teammate skips the code.
    public init(
        role: NearbyRole,
        localName: String,
        transport: any NearbyTransport,
        clock: any VaultClock = SystemClock(),
        team: TeamChatIdentityModel? = nil
    ) {
        self.init(
            machine: NearbyChatMachine(role: role, localName: localName, team: team),
            transport: transport,
            clock: clock
        )
    }

    /// Tests inject a machine with fixed key material.
    init(machine: NearbyChatMachine, transport: any NearbyTransport, clock: any VaultClock) {
        self.machine = machine
        role = machine.role
        self.transport = transport
        self.clock = clock
        (events, eventContinuation) = AsyncStream.makeStream(of: NearbyChatEvent.self)
        (outbox, outboxContinuation) = AsyncStream.makeStream(of: Data.self)
    }

    /// The current phase.
    public var phase: NearbyChatPhase {
        machine.phase
    }

    /// The code and peer name once keys exist.
    public var sas: NearbySASModel? {
        machine.sas
    }

    /// True when the session holds no keys, offers, providers or partial payloads (tests).
    var holdsNothing: Bool {
        machine.holdsNothing && providers.isEmpty && providerTasks.isEmpty
    }

    /// Keepalive PINGs not yet answered (tests).
    var unansweredPingCount: Int {
        machine.unansweredPings
    }

    // MARK: - Actions

    /// Starts the chat. The handshake begins once the transport reports `.connected`.
    /// Throws `.sessionFinished` on a second call.
    public func start() throws(ChatError) {
        guard !hasStarted else { throw .sessionFinished }
        hasStarted = true
        startSender()
        startReceiver()
        apply(try machine.start())
    }

    /// "Codes match".
    public func confirmSAS() throws(ChatError) {
        apply(try machine.confirmSAS())
    }

    /// "Don't match": aborts on both sides.
    public func rejectSAS() throws(ChatError) {
        apply(try machine.rejectSAS())
    }

    /// Sends one message (sanitized first). Returns it as sent, for the local transcript.
    @discardableResult
    public func sendText(_ text: String) throws(ChatError) -> ChatMessageModel {
        let (step, message) = try machine.sendText(text, at: clock.now)
        apply(step)
        guard let message else { throw .sessionFinished }
        return message
    }

    /// Offers one secret or variable (`manifest`: scope `secret`, one item with a value; any
    /// value in it is stripped). Only names, kind and scope travel now. `payloadProvider` runs
    /// only if the peer requests the value; if it throws, the offer is withdrawn.
    /// Call only after ReauthGate passed.
    @discardableResult
    public func offerAttachment(
        manifest: SharePackageModel,
        payloadProvider: @escaping ChatAttachmentValueProvider
    ) throws(ChatError) -> ChatAttachmentOfferModel {
        guard manifest.scope == .secret else { throw .invalidAttachment }
        let (step, offer) = try machine.offerAttachment(manifest)
        apply(step)
        guard let offer else { throw .sessionFinished }
        providers[offer.id] = .value(payloadProvider)
        return offer
    }

    /// True once both Macs speak chat v2 or later (v0.4.0): ``offerConfiguration(manifest:payloadProvider:)``
    /// is possible. False with a 0.2.x or 0.3.x peer, and before the keys exist.
    public var acceptsConfigurationAttachments: Bool {
        machine.acceptsConfigurationAttachments
    }

    /// Offers a whole repository or environment (v0.4.0; `manifest`: scope `repository` or
    /// `environment`; values are stripped). Only names and counts travel now.
    /// `payloadProvider` runs only if the peer requests it and must return the offered manifest
    /// with its values; if it throws or returns anything else, the offer is withdrawn.
    /// Call only after ReauthGate passed.
    ///
    /// - Throws: `.peerNeedsUpdate` when the peer runs chat v1 (FX Vault 0.3 or earlier).
    @discardableResult
    public func offerConfiguration(
        manifest: SharePackageModel,
        payloadProvider: @escaping ChatConfigurationPayloadProvider
    ) throws(ChatError) -> ChatAttachmentOfferModel {
        guard manifest.scope != .secret else { throw .invalidAttachment }
        let (step, offer) = try machine.offerAttachment(manifest)
        apply(step)
        guard let offer else { throw .sessionFinished }
        providers[offer.id] = .package(payloadProvider)
        return offer
    }

    /// "Save to my vault": asks the peer for the value of an offer it made.
    public func requestAttachment(_ id: ChatAttachmentID) throws(ChatError) {
        apply(try machine.requestAttachment(id))
    }

    /// "Dismiss": declines an offer the peer made (not yet requested).
    public func declineAttachment(_ id: ChatAttachmentID) throws(ChatError) {
        apply(try machine.declineAttachment(id))
    }

    /// Ends the chat and wipes everything (window closed, vault locked). Idempotent.
    public func close() {
        apply(machine.close())
    }

    // MARK: - Transport

    /// Sends frames in order. A failed send closes the transport instead of aborting here, so
    /// the receiver still processes what already arrived (for example the peer's ABORT) before
    /// the resulting `.disconnected`.
    private func startSender() {
        let outbox = outbox
        let transport = transport
        senderTask = Task {
            for await frame in outbox {
                do {
                    try await transport.send(frame)
                } catch {
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
        guard !machine.phase.isTerminal else { return }
        switch event {
        case .connected:
            apply(machine.transportConnected())
        case .received(let frame):
            apply(machine.receive(frame, at: clock.now))
        case .disconnected, .failed:
            apply(machine.abort(.disconnected))
        case .secondPeer:
            apply(machine.abort(.secondPeer))
        }
    }

    // MARK: - Steps

    private func apply(_ step: NearbyChatStep) {
        for frame in step.frames {
            outboxContinuation.yield(frame)
        }
        for event in step.events {
            eventContinuation.yield(event)
        }
        for id in step.payloadRequests {
            providePayload(id)
        }
        if machine.phase.isTerminal {
            shutDown()
            return
        }
        let kind = Self.timeoutKind(phase: machine.phase, role: role)
        if kind != phaseTimerKind || (kind == .chatIdle && step.isActivity) {
            restartPhaseTimer(kind)
        }
        if machine.phase == .chatting, keepaliveTask == nil {
            startKeepalive()
        }
    }

    /// The phase timer. A responder waiting for a peer has none; an initiator's handshake timer
    /// also bounds connecting.
    static func timeoutKind(phase: NearbyChatPhase, role: NearbyRole) -> NearbyTimeoutKind? {
        switch phase {
        case .awaitingPeer: role == .initiator ? .handshake : nil
        case .awaitingHello, .awaitingReveal: .handshake
        case .comparingCodes: .sas
        case .chatting: .chatIdle
        case .idle, .closed, .aborted: nil
        }
    }

    private func shutDown() {
        phaseTimer?.cancel()
        phaseTimer = nil
        phaseTimerKind = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        receiverTask?.cancel()
        receiverTask = nil
        for task in providerTasks.values {
            task.cancel()
        }
        providerTasks.removeAll()
        providers.removeAll()
        // The sender drains the remaining frames (CLOSE or ABORT), then closes the transport.
        outboxContinuation.finish()
        eventContinuation.finish()
    }

    // MARK: - Attachments

    /// What an offer's provider supplies once the peer requests it.
    private enum PayloadProvider {
        case value(ChatAttachmentValueProvider)
        case package(ChatConfigurationPayloadProvider)
    }

    private func providePayload(_ id: ChatAttachmentID) {
        guard let provider = providers.removeValue(forKey: id) else {
            apply(machine.withdrawAttachment(id))
            return
        }
        switch provider {
        case .value(let provider):
            providerTasks[id] = Task { [weak self] in
                let value: SecretBytes?
                do {
                    value = try await provider()
                } catch {
                    value = nil
                }
                guard let self else {
                    value?.wipe()
                    return
                }
                await self.deliverPayload(id, value: value)
            }
        case .package(let provider):
            providerTasks[id] = Task { [weak self] in
                let package: SharePackageModel?
                do {
                    package = try await provider()
                } catch {
                    package = nil
                }
                guard let self else {
                    package?.wipeValues()
                    return
                }
                await self.deliverPayload(id, package: package)
            }
        }
    }

    private func deliverPayload(_ id: ChatAttachmentID, value: SecretBytes?) {
        providerTasks[id] = nil
        defer { value?.wipe() }
        guard !machine.phase.isTerminal else { return }
        guard let value else {
            apply(machine.withdrawAttachment(id))
            return
        }
        do {
            apply(try machine.sendAttachmentPayload(id, value: value))
        } catch {
            apply(machine.withdrawAttachment(id))
        }
    }

    private func deliverPayload(_ id: ChatAttachmentID, package: SharePackageModel?) {
        providerTasks[id] = nil
        defer { package?.wipeValues() }
        guard !machine.phase.isTerminal else { return }
        guard let package else {
            apply(machine.withdrawAttachment(id))
            return
        }
        do {
            apply(try machine.sendAttachmentPayload(id, package: package))
        } catch {
            apply(machine.withdrawAttachment(id))
        }
    }

    // MARK: - Timers

    private func startKeepalive() {
        let clock = clock
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Timeouts.chatKeepaliveInterval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.keepaliveFired()
            }
        }
    }

    private func keepaliveFired() {
        guard !machine.phase.isTerminal else { return }
        apply(machine.keepaliveTick())
    }

    private func restartPhaseTimer(_ kind: NearbyTimeoutKind?) {
        phaseTimer?.cancel()
        phaseTimer = nil
        phaseTimerKind = kind
        phaseTimerGeneration += 1
        guard let kind else { return }
        let generation = phaseTimerGeneration
        let clock = clock
        phaseTimer = Task { [weak self] in
            do {
                try await clock.sleep(for: kind.duration)
            } catch {
                return
            }
            guard let self else { return }
            await self.phaseTimerFired(kind, generation: generation)
        }
    }

    private func phaseTimerFired(_ kind: NearbyTimeoutKind, generation: UInt64) {
        guard generation == phaseTimerGeneration, !machine.phase.isTerminal else { return }
        apply(machine.abort(.timeout(kind)))
    }
}
