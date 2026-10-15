import Foundation
import os
import Testing
import VaultCore
@testable import SharingKit

/// Chat v2 (v0.4.0): a whole repository or environment as one attachment, only when both Macs
/// offer chat version 2; a chat with a 0.2.x or 0.3.x Mac negotiates version 1 and keeps the
/// single-item rules.
@Suite("Nearby chat configuration attachments")
struct NearbyChatConfigurationTests {
    @Test(arguments: [(UInt8(2), UInt8(2), true), (2, 1, false), (1, 2, false), (1, 1, false)])
    func bothMacsMustOfferVersionTwo(initiator: UInt8, responder: UInt8, accepts: Bool) throws {
        var harness = try ChatHarness.kat(maxVersions: (initiator, responder))
        try harness.runToChatting()
        #expect(harness.initiator.acceptsConfigurationAttachments == accepts)
        #expect(harness.responder.acceptsConfigurationAttachments == accepts)
        #expect(harness.initiatorAbort == nil)
        #expect(harness.responderAbort == nil)
    }

    @Test func aChatV1RefusesAConfigurationBeforeAnythingIsSent() throws {
        var harness = try ChatHarness.kat(maxVersions: (2, 1))
        try harness.runToChatting()
        let framesBefore = harness.initiatorFrames.count
        #expect(throws: ChatError.peerNeedsUpdate) { _ = try harness.initiator.offerAttachment(PackageFactory.sample()) }
        #expect(harness.initiatorFrames.count == framesBefore)
        #expect(NearbyChatMachine.attachmentViolation(PackageFactory.sample().manifest(), acceptsConfiguration: false)
            == .invalidPackage(.scopeMismatch(.repository)))
    }

    @Test func aRepositoryTravelsAsOneAttachment() throws {
        var harness = try ChatHarness.kat(maxVersions: (2, 2))
        try harness.runToChatting()
        let package = PackageFactory.sample()
        defer { package.wipeValues() }
        let (offerStep, sent) = try harness.initiator.offerAttachment(package)
        harness.recordInitiator(offerStep)
        harness.pump()
        let offer = try #require(sent)
        #expect(offer.isConfiguration)
        #expect(offer.kind == nil)

        let card = try #require(harness.responderEvents.compactMap(\.offerModel).first)
        guard case .configuration(let summary) = card.content else {
            Issue.record("expected a configuration card")
            return
        }
        #expect(summary.environmentNames == package.repository.environments.map(\.name))
        #expect(summary.secretCount == package.flattenedItems.filter { $0.kind == .secret }.count)
        #expect(summary.valueMissingCount == 1)
        #expect(card.manifest.flattenedItems.allSatisfy { $0.item.value == nil }, "names only before a request")

        harness.recordResponder(try harness.responder.requestAttachment(card.id))
        harness.pump()
        #expect(harness.initiatorRequests == [card.id])
        #expect(throws: ChatError.invalidAttachment) {
            _ = try harness.initiator.sendAttachmentPayload(card.id, value: SecretBytes(utf8: "one value"))
        }
        harness.recordInitiator(try harness.initiator.sendAttachmentPayload(card.id, package: package))
        harness.pump()

        let (receivedID, payload) = try #require(harness.responderEvents.compactMap(\.receivedAttachment).first)
        defer { payload.wipeValues() }
        #expect(receivedID == card.id)
        #expect(payload.manifest() == card.manifest)
        let values = payload.flattenedItems.compactMap { $0.item.value?.utf8String() }
        #expect(values == package.flattenedItems.compactMap { $0.item.value?.utf8String() })
        #expect(harness.initiatorAbort == nil)
        #expect(harness.responderAbort == nil)
    }

    @Test func aPayloadThatDiffersFromTheOfferIsNotSent() throws {
        var harness = try ChatHarness.kat(maxVersions: (2, 2))
        try harness.runToChatting()
        let package = PackageFactory.sample()
        defer { package.wipeValues() }
        let (offerStep, sent) = try harness.initiator.offerAttachment(package)
        harness.recordInitiator(offerStep)
        harness.pump()
        let id = try #require(sent).id
        harness.recordResponder(try harness.responder.requestAttachment(id))
        harness.pump()

        var changed = package
        changed.repository.variables.append(PackageFactory.item("ADDED_SINCE"))
        let framesBefore = harness.initiatorFrames.count
        #expect(throws: ChatError.invalidAttachment) { _ = try harness.initiator.sendAttachmentPayload(id, package: changed) }
        #expect(harness.initiatorFrames.count == framesBefore, "nothing of the changed package left")
    }

    @Test func aConfigurationMayBeAsLargeAsANearbyShare() {
        #expect(NearbyChatMachine.payloadLimit(for: .secret) == Limits.chatAttachmentBytes)
        #expect(NearbyChatMachine.payloadLimit(for: .repository) == Limits.maxNearbyPayloadBytes)
        #expect(NearbyChatMachine.payloadLimit(for: .environment) == Limits.maxNearbyPayloadBytes)
    }

    // MARK: - Session

    @Test func theSessionAsksForTheConfigurationOnlyOnRequestAndWipesIt() async throws {
        let pair = InMemoryTransportPair()
        let parties = NearbyChatSessionTests.Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        try await parties.verify()
        #expect(await parties.initiator.acceptsConfigurationAttachments)

        let package = PackageFactory.sample()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let offer = try await parties.initiator.offerConfiguration(manifest: package.manifest()) {
            calls.withLock { $0 += 1 }
            return package
        }
        let card = await parties.responderEvents.first { $0.offerModel != nil }?.offerModel
        #expect(card?.isConfiguration == true)
        #expect(calls.withLock { $0 } == 0)
        let value = try #require(package.flattenedItems.first { $0.item.value != nil }?.item.value?.utf8String())
        #expect(pair.initiator.sentFrames.allSatisfy { $0.range(of: Data(value.utf8)) == nil })

        try await parties.responder.requestAttachment(offer.id)
        let delivered = await parties.responderEvents.first { $0.receivedAttachment != nil }?.receivedAttachment
        #expect(delivered?.1.manifest() == card?.manifest)
        delivered?.1.wipeValues()
        await parties.settle()
        #expect(calls.withLock { $0 } == 1)
        #expect(package.flattenedItems.allSatisfy { $0.item.value?.isWiped ?? true }, "the sender wipes what it sent")
        #expect(pair.initiator.sentFrames.allSatisfy { $0.range(of: Data(value.utf8)) == nil }, "encrypted on the wire")
        await parties.initiator.close()
    }

    @Test func aConfigurationChangedSinceTheOfferIsWithdrawn() async throws {
        let pair = InMemoryTransportPair()
        let parties = NearbyChatSessionTests.Parties(initiatorTransport: pair.initiator, responderTransport: pair.responder)
        try await parties.verify()
        let package = PackageFactory.sample()
        let offer = try await parties.initiator.offerConfiguration(manifest: package.manifest()) {
            var changed = package
            changed.repository.variables.append(PackageFactory.item("ADDED_SINCE"))
            return changed
        }
        _ = await parties.responderEvents.first { $0.offerModel != nil }
        try await parties.responder.requestAttachment(offer.id)
        #expect(await parties.responderEvents.first { $0 == .attachmentDeclined(offer.id) || $0.isTerminal }
            == .attachmentDeclined(offer.id))
        #expect(await parties.initiator.phase == .chatting)
        await parties.responder.close()
    }
}

/// v0.4.0: a package rebuilt for a configuration payload takes the offer's random entry ids.
@Suite("Share repository entry ids")
struct ShareRepositoryEntryIDTests {
    @Test func theSameShapeTakesTheOtherIDs() throws {
        let offered = PackageFactory.sample().manifest()
        let rebuilt = PackageFactory.sample()
        defer { rebuilt.wipeValues() }
        #expect(rebuilt.manifest().repository != offered.repository, "entry ids are random per package")

        let renumbered = try #require(rebuilt.repository.withEntryIDs(of: offered.repository))
        var payload = offered
        payload.repository = renumbered
        #expect(payload.allEntryIDs == offered.allEntryIDs)
        #expect(payload.manifest() == offered)
    }

    @Test func anotherShapeIsRefused() {
        let offered = PackageFactory.sample().manifest()
        var grown = PackageFactory.sample()
        defer { grown.wipeValues() }
        grown.repository.variables.append(PackageFactory.item("ADDED"))
        #expect(grown.repository.withEntryIDs(of: offered.repository) == nil)
        var fewerEnvironments = PackageFactory.sample()
        defer { fewerEnvironments.wipeValues() }
        fewerEnvironments.repository.environments.removeAll()
        #expect(fewerEnvironments.repository.withEntryIDs(of: offered.repository) == nil)
    }
}
