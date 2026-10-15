import Foundation
import SharingKit
import VaultCore

/// The sender (initiator) of a nearby share (§9.4, D21, D30), around one `NearbySession`.
///
/// 1. ``start()``, then show the code from `.sasReady` with "Codes match" / "Don't match"
///    (``confirmCode()`` / ``rejectCode()``).
/// 2. On `.readyForManifest` the app runs `ReauthGate.authorizeShare(.nearbySend, …)` and calls
///    ``sendManifest(_:senderName:appVersion:authorization:)``: the selection's values are
///    decrypted now and only the manifest (no values) is sent.
/// 3. When the receiver accepts (`.decisionReceived`), the accepted part is sent automatically
///    (manifest ∩ item ids, checked by the handshake). A decline sends nothing.
///
/// The package's values are wiped as soon as the payload was sent or the session ended. Every
/// event of the session is forwarded on ``events``. A session runs once: a new attempt needs a
/// new sender (no automatic retry).
public actor NearbyShareSender {
    /// The session's events, in order; ends when the session ends.
    public nonisolated let events: AsyncStream<NearbyEvent>
    private let continuation: AsyncStream<NearbyEvent>.Continuation
    private let session: NearbySession
    private let vault: VaultSession
    private let builder: ShareExportBuilder
    private var package: SharePackageModel?
    private var forwarder: Task<Void, Never>?

    init(session: NearbySession, vault: VaultSession, builder: ShareExportBuilder) {
        self.session = session
        self.vault = vault
        self.builder = builder
        (events, continuation) = AsyncStream.makeStream(of: NearbyEvent.self)
    }

    deinit {
        package?.wipeValues()
    }

    /// Starts the session (HELLO_I). Throws `.share(.nearbySessionFinished)` on a second call.
    public func start() async throws(SharingError) {
        guard forwarder == nil else { throw .share(.nearbySessionFinished) }
        let events = session.events
        forwarder = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
            await self?.finish()
        }
        do {
            try await session.start()
        } catch {
            throw .share(error)
        }
    }

    /// "Codes match".
    public func confirmCode() async throws(SharingError) {
        do {
            try await session.confirmSAS()
        } catch {
            throw .share(error)
        }
    }

    /// "Don't match": aborts on both sides with nothing transferred.
    public func rejectCode() async throws(SharingError) {
        do {
            try await session.rejectSAS()
        } catch {
            throw .share(error)
        }
    }

    /// Sends the manifest of `selection` (§9.4 step 7). Call only after both users confirmed
    /// the code (`.readyForManifest`).
    ///
    /// - Parameter authorization: from `ReauthGate.authorizeShare(.nearbySend, …)`; consumed.
    /// - Throws: `.authorizationInvalid`, `.nothingToShare`, `.share(.nearbyActionNotAllowed)`,
    ///   `.vault(.locked)`.
    public func sendManifest(
        _ selection: ShareSelectionModel,
        senderName: String,
        appVersion: String,
        authorization: ShareAuthorizationModel
    ) async throws(SharingError) {
        guard package == nil else { throw .share(.nearbyActionNotAllowed) }
        try authorization.consume(.nearbySend, for: vault)
        let built = try builder.build(selection, senderName: senderName, appVersion: appVersion, includeValues: true)
        do {
            try await session.sendManifest(built)
        } catch {
            built.wipeValues()
            throw .share(error)
        }
        package = built
    }

    /// Cancels the session (sheet closed, app locking). Idempotent.
    public func cancel() async {
        await session.cancel()
        wipePackage()
    }

    // MARK: - Private

    private func handle(_ event: NearbyEvent) async {
        continuation.yield(event)
        switch event {
        case .decisionReceived(let decision) where decision.accept:
            if let package {
                do {
                    try await session.sendPayload(package)
                } catch {
                    // Never leave the receiver waiting: end the session (the abort event follows).
                    await session.cancel()
                }
            }
            wipePackage()
        case .completed, .aborted:
            wipePackage()
        default:
            break
        }
    }

    private func finish() {
        wipePackage()
        continuation.finish()
    }

    private func wipePackage() {
        package?.wipeValues()
        package = nil
    }
}
