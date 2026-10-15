import Foundation
import SharingKit
import Testing
import VaultCore
@testable import VaultData
import VaultStore

/// ``NearbyShareSender`` and ``NearbyShareReceiver`` over an `InMemoryTransportPair` (§9.4):
/// two vaults with different keys, timers on `ManualClock` (they never fire here).
@Suite("Nearby share", .timeLimit(.minutes(1)))
struct NearbyShareTests {
    struct Parties {
        let world: ShareWorld
        let sender: NearbyShareSender
        let receiver: NearbyShareReceiver
        let senderEvents: StreamReader<NearbyEvent>
        let receiverEvents: StreamReader<NearbyEvent>
    }

    private func parties() async throws -> Parties {
        let world = try await ShareWorld.make()
        let pair = InMemoryTransportPair()
        let sender = await world.senderSharing.makeNearbySender(transport: pair.initiator, localName: "Sender Mac", clock: ManualClock())
        let receiver = await world.receiverSharing.makeNearbyReceiver(transport: pair.responder, localName: "Receiver Mac", clock: ManualClock())
        return Parties(
            world: world,
            sender: sender,
            receiver: receiver,
            senderEvents: StreamReader(sender.events),
            receiverEvents: StreamReader(receiver.events)
        )
    }

    /// Both started; returns both codes.
    private func handshake(_ parties: Parties) async throws -> (String?, String?) {
        try await parties.receiver.start()
        try await parties.sender.start()
        let senderCode = await parties.senderEvents.first { $0.isSAS || $0.isTerminal }?.sas?.code
        let receiverCode = await parties.receiverEvents.first { $0.isSAS || $0.isTerminal }?.sas?.code
        return (senderCode, receiverCode)
    }

    @Test func aNearbyShareAppliesThePayloadThroughTheImporter() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        let codes = try await handshake(parties)
        #expect(codes.0 != nil)
        #expect(codes.0 == codes.1)

        try await parties.sender.confirmCode()
        try await parties.receiver.confirmCode()
        _ = await parties.senderEvents.first { $0 == .readyForManifest || $0.isTerminal }
        let selection = ShareSelectionModel.repository(try parties.world.sender.repository().id)
        try await parties.sender.sendManifest(
            selection,
            senderName: ShareWorld.senderName,
            appVersion: ShareWorld.appVersion,
            authorization: parties.world.authorization(.nearbySend)
        )

        let manifestEvent = await parties.receiverEvents.first { $0.isManifest || $0.isTerminal }
        #expect(manifestEvent?.isManifest == true)
        let manifestPlan = try await parties.receiver.previewManifest(checkGitHub: false)
        #expect(manifestPlan.item("FXV_S1")?.chip == .new)
        #expect(manifestPlan.item("FXV_V1")?.chip == .existsLocally)
        #expect(manifestPlan.item("FXV_S2", environment: "production")?.chip == .fillsMissingValue)
        let decision = NearbyShareReceiver.decision(for: manifestPlan)
        #expect(decision.accept)
        #expect(decision.itemIDs.count == 4)
        try await parties.receiver.accept(manifestPlan)

        let payloadEvent = await parties.receiverEvents.first { $0.isPayload || $0.isTerminal }
        guard case .payloadReceived(let forwarded) = payloadEvent else {
            Issue.record("No payload: \(String(describing: payloadEvent))")
            return
        }
        // The UI never receives values.
        #expect(forwarded.flattenedItems.allSatisfy { $0.item.value == nil })

        let draft = try await parties.receiver.previewPayload(checkGitHub: false)
        #expect(draft.plan.item("FXV_V1")?.chip == .differs)
        #expect(draft.plan.item("FXV_S1")?.chip == .new)
        let result = try await parties.receiver.apply(draft.plan, confirmReplay: false)

        #expect(result.added.sorted() == ["FXV_S1", "production/FXV_V2"])
        #expect(result.filled == ["production/FXV_S2"])
        let completion = await parties.senderEvents.first { $0.isTerminal }
        #expect(completion == .completed(.transferred(receiverOK: true)))
        let receiver = parties.world.receiver
        let s1 = try #require(try receiver.item("FXV_S1", kind: .secret))
        #expect(try receiver.value(s1.id) == "a1")
        #expect(s1.provenance == .share)
        #expect(try receiver.value(try #require(try receiver.item("FXV_V1", kind: .variable)).id) == "different")
    }

    @Test func aRejectedPayloadImportsNothingAndTellsTheSender() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        _ = try await handshake(parties)
        try await parties.sender.confirmCode()
        try await parties.receiver.confirmCode()
        _ = await parties.senderEvents.first { $0 == .readyForManifest || $0.isTerminal }
        try await parties.sender.sendManifest(
            .item(try #require(try parties.world.sender.item("FXV_S1", kind: .secret)).id),
            senderName: ShareWorld.senderName,
            appVersion: ShareWorld.appVersion,
            authorization: parties.world.authorization(.nearbySend)
        )
        _ = await parties.receiverEvents.first { $0.isManifest || $0.isTerminal }
        let plan = try await parties.receiver.previewManifest(checkGitHub: false)
        #expect(plan.allItems.map(\.key.name) == ["FXV_S1"])
        try await parties.receiver.accept(plan)
        _ = await parties.receiverEvents.first { $0.isPayload || $0.isTerminal }
        let draft = try await parties.receiver.previewPayload(checkGitHub: false)
        try await parties.receiver.rejectPayload()
        #expect(draft.isClosedForApply)
        let completion = await parties.senderEvents.first { $0.isTerminal }
        #expect(completion == .completed(.transferred(receiverOK: false)))
        #expect(try parties.world.receiver.item("FXV_S1", kind: .secret) == nil)
        await #expect(throws: SharingError.share(.nearbyActionNotAllowed)) {
            _ = try await parties.receiver.apply(draft.plan, confirmReplay: false)
        }
    }

    @Test func declinedManifestTransfersNothing() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        _ = try await handshake(parties)
        try await parties.sender.confirmCode()
        try await parties.receiver.confirmCode()
        _ = await parties.senderEvents.first { $0 == .readyForManifest || $0.isTerminal }
        try await parties.sender.sendManifest(
            .repository(try parties.world.sender.repository().id),
            senderName: ShareWorld.senderName,
            appVersion: ShareWorld.appVersion,
            authorization: parties.world.authorization(.nearbySend)
        )
        _ = await parties.receiverEvents.first { $0.isManifest || $0.isTerminal }
        try await parties.receiver.decline()
        let completion = await parties.senderEvents.first { $0.isTerminal }
        #expect(completion == .completed(.declined))
        #expect(try parties.world.receiver.item("FXV_S1", kind: .secret) == nil)
        await #expect(throws: SharingError.share(.nearbyActionNotAllowed)) {
            _ = try await parties.receiver.previewPayload(checkGitHub: false)
        }
    }

    @Test func dontMatchAbortsBeforeAnyManifest() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        _ = try await handshake(parties)
        try await parties.receiver.rejectCode()
        let senderEnd = await parties.senderEvents.first { $0.isTerminal }
        let receiverEnd = await parties.receiverEvents.first { $0.isTerminal }
        #expect(senderEnd?.isAbort == true)
        #expect(receiverEnd?.isAbort == true)
        // A manifest can no longer be sent; the authorization was not consumed.
        let authorization = parties.world.authorization(.nearbySend)
        await #expect(throws: SharingError.self) {
            try await parties.sender.sendManifest(
                .repository(try parties.world.sender.repository().id),
                senderName: ShareWorld.senderName,
                appVersion: ShareWorld.appVersion,
                authorization: authorization
            )
        }
        await #expect(throws: SharingError.share(.nearbyActionNotAllowed)) {
            _ = try await parties.receiver.previewManifest(checkGitHub: false)
        }
    }

    @Test func theManifestNeedsTheNearbyAuthorization() async throws {
        let parties = try await parties()
        defer { parties.world.folder.remove() }
        _ = try await handshake(parties)
        try await parties.sender.confirmCode()
        try await parties.receiver.confirmCode()
        _ = await parties.senderEvents.first { $0 == .readyForManifest || $0.isTerminal }
        await #expect(throws: SharingError.authorizationInvalid) {
            try await parties.sender.sendManifest(
                .repository(try parties.world.sender.repository().id),
                senderName: ShareWorld.senderName,
                appVersion: ShareWorld.appVersion,
                authorization: parties.world.authorization(.fileExport)
            )
        }
        await parties.sender.cancel()
        #expect(await parties.receiverEvents.first { $0.isTerminal }?.isAbort == true)
    }
}

extension NearbyEvent {
    var sas: NearbySASModel? {
        if case .sasReady(let model) = self { return model }
        return nil
    }

    var isSAS: Bool {
        sas != nil
    }

    var isManifest: Bool {
        if case .manifestReceived = self { return true }
        return false
    }

    var isPayload: Bool {
        if case .payloadReceived = self { return true }
        return false
    }

    var isAbort: Bool {
        if case .aborted = self { return true }
        return false
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .aborted: true
        default: false
        }
    }
}
