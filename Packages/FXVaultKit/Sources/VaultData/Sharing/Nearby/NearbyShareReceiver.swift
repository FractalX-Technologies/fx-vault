import Foundation
import SharingKit
import VaultCore

/// The receiver (responder) of a nearby share (§9.4, §9.5), around one `NearbySession`.
///
/// 1. ``start()`` while "Receive nearby" is open, then compare the code (``confirmCode()`` /
///    ``rejectCode()``).
/// 2. On `.manifestReceived`: ``previewManifest(checkGitHub:)`` gives the chips that need no
///    values (New / Fills missing value / Value not included / Exists locally). The user picks,
///    then ``accept(_:)`` sends a DECISION with the item ids the plan needs (every item that
///    would change, plus existing ones so Same/Differs can be computed), or ``decline()``.
/// 3. On `.payloadReceived`: ``previewPayload(checkGitHub:)`` plans the values (Same / Differs);
///    the user confirms once more, then ``apply(_:confirmReplay:)`` imports through the same
///    importer as a file and sends RESULT ok, or ``rejectPayload()`` sends RESULT not ok.
///
/// Events are forwarded on ``events``; a received payload is forwarded **without** values (its
/// manifest). Values are wiped once applied, rejected or when the session ends.
public actor NearbyShareReceiver {
    /// The session's events, in order; ends when the session ends.
    public nonisolated let events: AsyncStream<NearbyEvent>
    private let continuation: AsyncStream<NearbyEvent>.Continuation
    private let session: NearbySession
    private let repository: SharingRepository
    private var manifest: SharePackageModel?
    private var payload: SharePackageModel?
    private var payloadDraft: ShareImportDraftModel?
    private var forwarder: Task<Void, Never>?

    init(session: NearbySession, repository: SharingRepository) {
        self.session = session
        self.repository = repository
        (events, continuation) = AsyncStream.makeStream(of: NearbyEvent.self)
    }

    deinit {
        payload?.wipeValues()
    }

    /// Starts the session (waits for HELLO_I). Throws `.share(.nearbySessionFinished)` on a
    /// second call.
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

    /// The manifest preview (§9.5: chips computable without values).
    ///
    /// - Throws: `.share(.nearbyActionNotAllowed)` before a manifest arrived, `.vault(.locked)`.
    public func previewManifest(checkGitHub: Bool = true) async throws(SharingError) -> ShareImportPlanModel {
        guard let manifest else { throw .share(.nearbyActionNotAllowed) }
        return try await repository.draft(for: manifest, mode: .manifest, checkGitHub: checkGitHub).plan
    }

    /// Accepts the items `plan` needs (DECISION, §9.4 step 8). A plan that needs nothing
    /// declines instead.
    public func accept(_ plan: ShareImportPlanModel) async throws(SharingError) {
        try await sendDecision(Self.decision(for: plan))
    }

    /// Declines the manifest; nothing is transferred.
    public func decline() async throws(SharingError) {
        try await sendDecision(.decline)
    }

    /// The payload preview (Same / Differs, §9.5). The draft holds the values until applied
    /// or rejected.
    ///
    /// - Throws: `.share(.nearbyActionNotAllowed)` before the payload arrived, `.vault(.locked)`.
    public func previewPayload(checkGitHub: Bool = true) async throws(SharingError) -> ShareImportDraftModel {
        guard let payload else { throw .share(.nearbyActionNotAllowed) }
        let draft = try await repository.draft(for: payload, mode: .payload, checkGitHub: checkGitHub)
        payloadDraft?.discard()
        payloadDraft = draft
        return draft
    }

    /// Imports the reviewed payload `plan` and reports RESULT ok to the sender.
    ///
    /// On `.replayNotConfirmed` or `.planOutdated` nothing is sent: confirm, or preview the
    /// payload again, and retry.
    @discardableResult
    public func apply(_ plan: ShareImportPlanModel, confirmReplay: Bool) async throws(SharingError) -> ShareImportResultModel {
        guard let payloadDraft else { throw .share(.nearbyActionNotAllowed) }
        let result = try await repository.apply(payloadDraft, plan: plan, confirmReplay: confirmReplay)
        wipePayload()
        do {
            try await session.sendResult(ok: true)
        } catch {
            throw .share(error)
        }
        return result
    }

    /// Rejects the payload: nothing is imported and the sender is told (RESULT not ok).
    public func rejectPayload() async throws(SharingError) {
        wipePayload()
        do {
            try await session.sendResult(ok: false)
        } catch {
            throw .share(error)
        }
    }

    /// Cancels the session (sheet closed, app locking). Idempotent.
    public func cancel() async {
        await session.cancel()
        wipePayload()
    }

    /// The DECISION for a manifest plan: every item whose selected action changes something,
    /// every item that exists locally (Same/Differs needs its value), and every environment
    /// that would be created or get the incoming policy. A missing partial environment counts
    /// only with at least one accepted item: alone its id asks for nothing (§1.2).
    static func decision(for plan: ShareImportPlanModel) -> NearbyDecisionModel {
        var ids: Set<ShareEntryID> = []
        for item in plan.allItems where item.action != .skip || item.chip == .existsLocally {
            ids.insert(item.id)
        }
        for environment in plan.environments {
            switch environment.action {
            case .create:
                if environment.includesBranchPolicy || environment.items.contains(where: { ids.contains($0.id) }) {
                    ids.insert(environment.id)
                }
            case .useExisting where environment.policyDifference?.decision == .useIncoming:
                ids.insert(environment.id)
            default:
                break
            }
        }
        return ids.isEmpty ? .decline : NearbyDecisionModel(accept: true, itemIDs: ids)
    }

    // MARK: - Private

    private func sendDecision(_ decision: NearbyDecisionModel) async throws(SharingError) {
        do {
            try await session.sendDecision(decision)
        } catch {
            throw .share(error)
        }
    }

    private func handle(_ event: NearbyEvent) {
        switch event {
        case .manifestReceived(let received):
            manifest = received
            continuation.yield(event)
        case .payloadReceived(let received):
            payload = received
            continuation.yield(.payloadReceived(received.manifest()))
        case .completed, .aborted:
            wipePayload()
            continuation.yield(event)
        default:
            continuation.yield(event)
        }
    }

    private func finish() {
        wipePayload()
        continuation.finish()
    }

    private func wipePayload() {
        payloadDraft?.discard()
        payloadDraft = nil
        payload?.wipeValues()
        payload = nil
    }
}
