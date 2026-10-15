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

    // MARK: - Configurations (sender, v0.4.0)

    /// True once both Macs speak chat v2 (FX Vault 0.4 or later): a whole repository can be
    /// attached. Check it before asking for Touch ID or the master password.
    public var acceptsConfigurationAttachments: Bool {
        get async { await session.acceptsConfigurationAttachments }
    }

    /// Offers a repository's whole configuration (repository level and every environment with its
    /// branch policy): only names and counts travel now. The values are read, inside
    /// `VaultSession.read`, only when the peer asks, and only if nothing changed since the offer.
    ///
    /// - Parameter authorization: from `ReauthGate.authorizeShare(.nearbySend, …)`; consumed here.
    /// - Throws: `.chat(.peerNeedsUpdate)` with a 0.3 or older peer (before the authorization is
    ///   used), `.sharing(.authorizationInvalid)`, `.sharing(.repositoryNotFound)`,
    ///   `.sharing(.nothingToShare)`, `.sharing(.vault(.locked))`, `.chat(…)`.
    @discardableResult
    public func offerRepository(
        _ repositoryID: RepoID,
        senderName: String,
        appVersion: String,
        authorization: ShareAuthorizationModel
    ) async throws(NearbyChatError) -> ChatAttachmentOfferModel {
        guard await session.acceptsConfigurationAttachments else { throw .chat(.peerNeedsUpdate) }
        let manifest: SharePackageModel
        let fingerprints: [ConfigItemID: Data?]
        do {
            try authorization.consume(.nearbySend, for: vault)
            manifest = try builder.build(.repository(repositoryID), senderName: senderName, appVersion: appVersion, includeValues: false)
            fingerprints = try Self.storedFingerprints(ofRepository: repositoryID, vault: vault)
        } catch {
            throw .sharing(error)
        }
        let provider = Self.configurationProvider(
            for: repositoryID,
            offered: manifest,
            fingerprints: fingerprints,
            vault: vault,
            builder: builder,
            senderName: senderName,
            appVersion: appVersion
        )
        do {
            return try await session.offerConfiguration(manifest: manifest, payloadProvider: provider)
        } catch {
            throw .chat(error)
        }
    }

    /// Reads the offered repository's values when the peer asks for them. Refuses (the session
    /// then withdraws the offer) when anything changed since the user authorized the offer: an
    /// item or environment added, removed, renamed or re-policied, or a value edited (the stored
    /// keyed `value_fp` of every item), or when the vault is locked.
    private static func configurationProvider(
        for repositoryID: RepoID,
        offered: SharePackageModel,
        fingerprints: [ConfigItemID: Data?],
        vault: VaultSession,
        builder: ShareExportBuilder,
        senderName: String,
        appVersion: String
    ) -> ChatConfigurationPayloadProvider {
        {
            let fresh = try builder.build(.repository(repositoryID), senderName: senderName, appVersion: appVersion, includeValues: true)
            // The values go to the session (which wipes them once sent) or are wiped here, also
            // when reading the fingerprints throws.
            var isHandedOver = false
            defer {
                if !isHandedOver {
                    fresh.wipeValues()
                }
            }
            var payload = offered
            if let repository = fresh.repository.withEntryIDs(of: offered.repository) {
                payload.repository = repository
            }
            // Checked after reading the values: a change in between also refuses.
            guard try storedFingerprints(ofRepository: repositoryID, vault: vault) == fingerprints,
                  payload.manifest() == offered.manifest(),
                  payload.flattenedItems.allSatisfy({ ($0.item.value != nil) == ($0.item.valueState == .present) })
            else { throw NearbyChatError.attachmentUnavailable }
            isHandedOver = true
            return payload
        }
    }

    /// The stored value fingerprints (`value_fp`, keyed, never values) of every item of the
    /// repository that is not deleted.
    private static func storedFingerprints(ofRepository repositoryID: RepoID, vault: VaultSession) throws(SharingError) -> [ConfigItemID: Data?] {
        let database = vault.database
        return try performSharing {
            try vault.read { _, tx in
                let records = try ConfigStore(database: database).fetchItemRecords(repositoryID: repositoryID, in: tx)
                return Dictionary(
                    records.filter { !$0.isDeleted }.map { ($0.id, $0.valueFingerprint) },
                    uniquingKeysWith: { first, _ in first }
                )
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

    /// Plans the received values against this vault (the share import preview, §9.5). The values
    /// move into the returned draft (apply it with `SharingRepository.apply`, or `discard()` it);
    /// nothing is kept here.
    ///
    /// - Parameter target: v0.4.0 "Import into…": a repository of this vault the user chose
    ///   instead of the sender's `owner/name` (the package is planned and imported as if it were
    ///   for that repository). Nil plans it for the sender's repository, as before.
    /// - Throws: `.attachmentUnavailable` (not received, already previewed or wiped),
    ///   `.sharing(.repositoryNotFound)` (target), `.sharing(.vault(.locked))`, `.sharing(…)`.
    public func previewAttachment(
        _ id: ChatAttachmentID,
        into target: RepoID? = nil,
        checkGitHub: Bool
    ) async throws(NearbyChatError) -> ShareImportDraftModel {
        guard let package = received.removeValue(forKey: id) else { throw .attachmentUnavailable }
        defer { package.wipeValues() }
        do {
            let planned = if let target {
                try Self.retargeted(package, to: target, vault: vault)
            } else {
                package
            }
            return try await sharing.draft(for: planned, mode: .payload, checkGitHub: checkGitHub)
        } catch {
            throw .sharing(error)
        }
    }

    /// v0.4.0 "Save as File…": writes the received package to an encrypted `.fxvault` file under a
    /// fresh passphrase (shown once), keeping the sender's name and package id. The package stays
    /// here, so it can still be imported.
    ///
    /// - Parameter authorization: from `ReauthGate.authorizeShare(.fileExport, …)`; consumed here.
    /// - Throws: `.attachmentUnavailable`, `.sharing(.authorizationInvalid)`, `.sharing(.write(…))`.
    public func saveAttachment(
        _ id: ChatAttachmentID,
        to destination: URL,
        authorization: ShareAuthorizationModel
    ) async throws(NearbyChatError) -> ShareFileExportResultModel {
        guard let package = received[id] else { throw .attachmentUnavailable }
        do {
            return try await sharing.exportFile(package: package, to: destination, authorization: authorization)
        } catch {
            throw .sharing(error)
        }
    }

    /// Names and counts of a received package (no values), for "Save as File…"; nil when it has
    /// not arrived or was already imported or wiped.
    public func receivedPreview(_ id: ChatAttachmentID) -> ShareExportPreviewModel? {
        received[id].map { ShareExportBuilder.preview($0) }
    }

    /// `package` as if it were for the vault repository `target` (its owner, name and GitHub id).
    private static func retargeted(
        _ package: SharePackageModel,
        to target: RepoID,
        vault: VaultSession
    ) throws(SharingError) -> SharePackageModel {
        let database = vault.database
        let repository = try performSharing {
            try vault.read { _, tx in try RepoStore(database: database).fetch(id: target, in: tx) }
        }
        guard let repository else { throw .repositoryNotFound }
        var copy = package
        copy.repository.owner = repository.ownerLogin
        copy.repository.name = repository.name
        copy.repository.githubRepoID = repository.githubID
        return copy
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
