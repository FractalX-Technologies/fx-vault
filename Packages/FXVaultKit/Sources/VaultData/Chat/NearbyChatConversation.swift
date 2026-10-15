import Foundation
import SharingKit
import VaultCore
import VaultStore

/// One nearby chat as the chat window sees it (v0.2.0, experimental), around one
/// `NearbyChatSession`.
///
/// 1. ``start()``, compare the code (``confirmCode()`` / ``rejectCode()``), then chat with
///    ``sendText(_:)``.
/// 2. **Attach:** after `ReauthGate.authorizeShare(.nearbySend, …)`,
///    ``offerItem(_:senderName:appVersion:authorization:)`` sends the item's names only. Its value
///    is decrypted (inside `VaultSession.read`) only when the peer asks for it, and wiped as soon
///    as it was sent.
/// 3. **Save:** ``requestAttachment(_:)`` asks the peer for the value of its offer. The payload is
///    kept here and forwarded on ``events`` **without** its value; ``previewAttachment(_:checkGitHub:)``
///    plans it like any share (`ShareImportPlanner`) and hands the draft to
///    `SharingRepository.apply`, which re-encrypts the value under this vault's key.
///
/// Ephemeral: no message history is kept. ``close()`` (window closed, vault locked), an abort
/// and a disconnect wipe every received value; the session wipes its keys, offers and value
/// providers. A conversation runs once.
public actor NearbyChatConversation {
    /// The chat's events, in order; a received attachment arrives as its manifest (no value).
    /// Finishes when the chat ends.
    public nonisolated let events: AsyncStream<NearbyChatEvent>
    public nonisolated let role: NearbyRole

    private let continuation: AsyncStream<NearbyChatEvent>.Continuation
    private let session: NearbyChatSession
    private let vault: VaultSession
    private let builder: ShareExportBuilder
    private let sharing: SharingRepository
    private var forwarder: Task<Void, Never>?
    private var received: [ChatAttachmentID: SharePackageModel] = [:]

    init(session: NearbyChatSession, vault: VaultSession, builder: ShareExportBuilder, sharing: SharingRepository) {
        self.session = session
        role = session.role
        self.vault = vault
        self.builder = builder
        self.sharing = sharing
        (events, continuation) = AsyncStream.makeStream(of: NearbyChatEvent.self)
    }

    deinit {
        for package in received.values {
            package.wipeValues()
        }
    }

    /// Received values not yet previewed or wiped (tests).
    var receivedCount: Int {
        received.count
    }

    // MARK: - Chat

    /// Starts the chat (advertising responder: waits for a peer; initiator: HELLO).
    public func start() async throws(NearbyChatError) {
        guard forwarder == nil else { throw .chat(.sessionFinished) }
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
            throw .chat(error)
        }
    }

    /// "Codes match".
    public func confirmCode() async throws(NearbyChatError) {
        do {
            try await session.confirmSAS()
        } catch {
            throw .chat(error)
        }
    }

    /// "Don't match": ends the chat on both sides.
    public func rejectCode() async throws(NearbyChatError) {
        do {
            try await session.rejectSAS()
        } catch {
            throw .chat(error)
        }
    }

    /// Sends one message (sanitized first) and returns it as sent, for the local transcript.
    @discardableResult
    public func sendText(_ text: String) async throws(NearbyChatError) -> ChatMessageModel {
        do {
            return try await session.sendText(text)
        } catch {
            throw .chat(error)
        }
    }

    /// Ends the chat and wipes every received value. Idempotent.
    public func close() async {
        await session.close()
        wipeReceived()
    }

    // MARK: - Attachments (sender)

    /// Offers one secret or variable: only its name, kind and scope travel now.
    ///
    /// - Parameter authorization: from `ReauthGate.authorizeShare(.nearbySend, …)`; consumed here.
    /// - Throws: `.sharing(.authorizationInvalid)`, `.sharing(.itemNotFound)` (deleted, or its
    ///   environment), `.valueMissing`, `.sharing(.vault(.locked))`, `.chat(…)` (not chatting,
    ///   too many open offers, ...).
    @discardableResult
    public func offerItem(
        _ itemID: ConfigItemID,
        senderName: String,
        appVersion: String,
        authorization: ShareAuthorizationModel
    ) async throws(NearbyChatError) -> ChatAttachmentOfferModel {
        let manifest: SharePackageModel
        do {
            try authorization.consume(.nearbySend, for: vault)
            manifest = try builder.build(.item(itemID), senderName: senderName, appVersion: appVersion, includeValues: false)
        } catch {
            throw .sharing(error)
        }
        guard manifest.itemCount == 1, let offered = manifest.flattenedItems.first else {
            throw .sharing(.itemNotFound)
        }
        guard offered.item.valueState == .present else { throw .valueMissing }
        let fingerprint: Data?
        do {
            fingerprint = try Self.storedFingerprint(of: itemID, vault: vault)
        } catch {
            throw .sharing(error)
        }
        let provider = Self.valueProvider(
            for: itemID,
            matching: offered,
            fingerprint: fingerprint,
            vault: vault,
            builder: builder,
            senderName: senderName,
            appVersion: appVersion
        )
        do {
            return try await session.offerAttachment(manifest: manifest, payloadProvider: provider)
        } catch {
            throw .chat(error)
        }
    }

    /// Decrypts the offered item's value when the peer asks for it. Refuses (the session then
    /// withdraws the offer) when the item is gone, moved, renamed or changed kind since the
    /// offer, its value changed since the user authorized the offer (`fingerprint`, the stored
    /// keyed `value_fp`), or the vault is locked.
    private static func valueProvider(
        for itemID: ConfigItemID,
        matching offered: ShareLocatedItemModel,
        fingerprint: Data?,
        vault: VaultSession,
        builder: ShareExportBuilder,
        senderName: String,
        appVersion: String
    ) -> ChatAttachmentValueProvider {
        let name = offered.item.name
        let kind = offered.kind
        let environmentName = offered.environmentName
        return {
            let package = try builder.build(.item(itemID), senderName: senderName, appVersion: appVersion, includeValues: true)
            defer { package.wipeValues() }
            // Checked after reading the value: a change in between also refuses.
            guard try storedFingerprint(of: itemID, vault: vault) == fingerprint,
                  package.itemCount == 1,
                  let current = package.flattenedItems.first,
                  current.item.name == name,
                  current.kind == kind,
                  current.environmentName == environmentName,
                  let value = current.item.value
            else { throw NearbyChatError.attachmentUnavailable }
            return value.copy()
        }
    }

    /// The item's stored value fingerprint (`value_fp`, keyed and bound to the row; never the
    /// value), nil when it has no value or is gone.
    private static func storedFingerprint(of itemID: ConfigItemID, vault: VaultSession) throws(SharingError) -> Data? {
        let database = vault.database
        return try performSharing {
            try vault.read { _, tx in
                try ConfigStore(database: database).fetchItemRecord(id: itemID, in: tx)?.valueFingerprint
            }
        }
    }

    // MARK: - Attachments (receiver)

    /// "Save to my vault": asks the peer for the value of its offer. The value arrives as
    /// `.attachmentReceived` (forwarded without the value).
    public func requestAttachment(_ id: ChatAttachmentID) async throws(NearbyChatError) {
        do {
            try await session.requestAttachment(id)
        } catch {
            throw .chat(error)
        }
    }

    /// "Dismiss": declines the peer's offer (nothing is sent).
    public func declineAttachment(_ id: ChatAttachmentID) async throws(NearbyChatError) {
        do {
            try await session.declineAttachment(id)
        } catch {
            throw .chat(error)
        }
    }

    /// Plans the received value against this vault (the share import preview, §9.5). The value
    /// moves into the returned draft (apply it with `SharingRepository.apply`, or `discard()` it);
    /// nothing is kept here.
    ///
    /// - Throws: `.attachmentUnavailable` (not received, already previewed or wiped),
    ///   `.sharing(.vault(.locked))`, `.sharing(…)`.
    public func previewAttachment(_ id: ChatAttachmentID, checkGitHub: Bool) async throws(NearbyChatError) -> ShareImportDraftModel {
        guard let package = received.removeValue(forKey: id) else { throw .attachmentUnavailable }
        defer { package.wipeValues() }
        do {
            return try await sharing.draft(for: package, mode: .payload, checkGitHub: checkGitHub)
        } catch {
            throw .sharing(error)
        }
    }

    /// Wipes a received value the user chose not to save. Idempotent.
    public func discardAttachment(_ id: ChatAttachmentID) {
        received.removeValue(forKey: id)?.wipeValues()
    }

    // MARK: - Private

    private func handle(_ event: NearbyChatEvent) {
        switch event {
        case .attachmentReceived(let id, let package):
            received.removeValue(forKey: id)?.wipeValues()
            received[id] = package
            continuation.yield(.attachmentReceived(id, package.manifest()))
        case .peerClosed, .aborted:
            wipeReceived()
            continuation.yield(event)
        default:
            continuation.yield(event)
        }
    }

    private func finish() {
        wipeReceived()
        continuation.finish()
    }

    private func wipeReceived() {
        for package in received.values {
            package.wipeValues()
        }
        received.removeAll()
    }
}
