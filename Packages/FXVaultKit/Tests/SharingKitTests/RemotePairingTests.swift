import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// Remote pairing by `.fxvcard` files (v0.9.0, P4): invitation, reply, the 6-word code, the
/// sealed announce key, signatures, age and own-card checks.
@Suite("Remote pairing")
struct RemotePairingTests {
    let pairing: RemotePairing
    let ana = TeamDeviceKeys.generate()
    let ben = TeamDeviceKeys.generate()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        pairing = try RemotePairing.bundled()
    }

    private func invitation(from keys: TeamDeviceKeys? = nil, at date: Date? = nil) throws -> Data {
        try pairing.makeInvitation(
            keys: keys ?? ana,
            login: "user-a",
            displayName: "Ana",
            macName: "Ana's Mac",
            now: date ?? now
        )
    }

    private func reply(to file: Data, from keys: TeamDeviceKeys? = nil, at date: Date? = nil) throws -> RemotePairingReplyFileModel {
        let keys = keys ?? ben
        let read = try pairing.readInvitation(file, now: date ?? now, ownDevice: keys.deviceID)
        return try pairing.makeReply(to: read, keys: keys, login: "user-b", displayName: "Ben", macName: "Ben's Mac", now: date ?? now)
    }

    private func expectError(_ expected: ShareError, _ body: () throws -> Void) {
        #expect(throws: expected) { try body() }
    }

    // MARK: - Round trip

    @Test func invitationReplyAndBothCodesMatch() throws {
        let file = try invitation()
        let read = try pairing.readInvitation(file, now: now, ownDevice: ben.deviceID)
        #expect(read.inviter.deviceID == ana.deviceID)
        #expect(read.inviter.name == "Ana")
        #expect(read.inviter.login == "user-a")
        #expect(read.inviter.macName == "Ana's Mac")
        #expect(read.createdAt == now)

        let answer = try pairing.makeReply(to: read, keys: ben, login: "user-b", displayName: "Ben", macName: "Ben's Mac", now: now)
        #expect(answer.inviter == read.inviter)
        let received = try pairing.readReply(answer.file, keys: ana, now: now)
        #expect(received.code == answer.code)
        #expect(received.code.words.count == RemotePairingProtocol.codeWordCount)
        let wordlist = try PassphraseGenerator.bundled()
        #expect(received.code.words.allSatisfy(wordlist.contains))
        #expect(received.code.text.split(separator: "-").count == RemotePairingProtocol.codeWordCount)
        #expect(received.teammate == ben.card(login: "user-b", displayName: "Ben", macName: "Ben's Mac"))
        #expect(received.createdAt == now)
    }

    @Test func theInviterIsStoredWithItsAnnounceKeyOnceKnown() throws {
        let read = try pairing.readInvitation(try invitation(), now: now, ownDevice: ben.deviceID)
        let full = try read.inviter.withAnnounceKey(ana.card(login: "", displayName: "", macName: "").announceKey)
        #expect(full == ana.card(login: "user-a", displayName: "Ana", macName: "Ana's Mac"))
        #expect(throws: ShareError.teamCardInvalid) { try read.inviter.withAnnounceKey(Data(count: 3)) }
    }

    @Test func kindRoutesFiles() throws {
        let file = try invitation()
        #expect(try RemotePairing.kind(of: file) == .invitation)
        #expect(try RemotePairing.kind(of: try reply(to: file).file) == .reply)
        expectError(.invalidPairingCard) { _ = try RemotePairing.kind(of: Data("hello".utf8)) }
        expectError(.invalidPairingCard) { _ = try RemotePairing.kind(of: Data(RemotePairingProtocol.magic)) }
        // An invitation is not a reply, and the other way round.
        expectError(.invalidPairingCard) { _ = try pairing.readReply(file, keys: ana, now: now) }
        let answer = try reply(to: file)
        expectError(.invalidPairingCard) { _ = try pairing.readInvitation(answer.file, now: now, ownDevice: ben.deviceID) }
    }

    // MARK: - The announce key never travels in the clear

    @Test func cardFilesNeverCarryAnAnnounceKeyInTheClear() throws {
        let file = try invitation()
        #expect(file.range(of: ana.card(login: "", displayName: "", macName: "").announceKey) == nil)
        let answer = try reply(to: file)
        #expect(answer.file.range(of: ana.card(login: "", displayName: "", macName: "").announceKey) == nil)
        #expect(answer.file.range(of: ben.card(login: "", displayName: "", macName: "").announceKey) == nil)
    }

    // MARK: - Forged or damaged files

    @Test func aReplyToAnotherMacsInvitationIsRefused() throws {
        let carol = TeamDeviceKeys.generate()
        let answer = try reply(to: try invitation(from: carol))
        expectError(.invalidPairingCard) { _ = try pairing.readReply(answer.file, keys: ana, now: now) }
    }

    @Test func everyFlippedInvitationByteIsRefused() throws {
        let file = try invitation()
        for index in file.indices {
            var damaged = file
            damaged[index] ^= 0x01
            expectError(.invalidPairingCard) { _ = try pairing.readInvitation(damaged, now: now, ownDevice: ben.deviceID) }
        }
        expectError(.invalidPairingCard) { _ = try pairing.readInvitation(file.dropLast(), now: now, ownDevice: ben.deviceID) }
        expectError(.invalidPairingCard) { _ = try pairing.readInvitation(file + Data([0]), now: now, ownDevice: ben.deviceID) }
    }

    @Test func everyFlippedReplyByteIsRefused() throws {
        let file = try reply(to: try invitation()).file
        for index in file.indices {
            var damaged = file
            damaged[index] ^= 0x01
            expectError(.invalidPairingCard) { _ = try pairing.readReply(damaged, keys: ana, now: now) }
        }
        expectError(.invalidPairingCard) { _ = try pairing.readReply(file.dropLast(), keys: ana, now: now) }
        expectError(.invalidPairingCard) { _ = try pairing.readReply(file + Data([0]), keys: ana, now: now) }
    }

    @Test func anInvitationSignedByAnotherKeyIsRefused() throws {
        let carol = TeamDeviceKeys.generate()
        let card = TeamPublicCardModel(keys: ana, login: "user-a", displayName: "Ana", macName: "Ana's Mac")
        let signed = RemotePairing.invitationSigned(card: card, createdAt: RemotePairing.seconds(now), nonce: Data(count: Limits.pairingNonceBytes))
        var file = Data(RemotePairingProtocol.magic) + Data([RemotePairingProtocol.version, RemotePairingFileKind.invitation.rawValue])
        file.append(signed)
        file.append(try carol.sign(RemotePairing.invitationMessage(signed)))
        expectError(.invalidPairingCard) { _ = try pairing.readInvitation(file, now: now, ownDevice: ben.deviceID) }
    }

    @Test func aReplySignedByAnotherKeyIsRefused() throws {
        let file = try reply(to: try invitation()).file
        let carol = TeamDeviceKeys.generate()
        let body = file.dropFirst(RemotePairingProtocol.headerBytes).dropLast(TeamProtocol.signatureBytes)
        let forged = file.dropLast(TeamProtocol.signatureBytes) + (try carol.sign(RemotePairing.replyMessage(Data(body))))
        expectError(.invalidPairingCard) { _ = try pairing.readReply(Data(forged), keys: ana, now: now) }
    }

    @Test func aReplyOpensOnlyWithTheInvitersKeys() throws {
        let file = try reply(to: try invitation()).file
        // Another Mac cannot pass for the inviter, even with the inviter's public card.
        expectError(.invalidPairingCard) { _ = try pairing.readReply(file, keys: TeamDeviceKeys.generate(), now: now) }
        // The same keys with a new announce key still open it (the device is the same).
        #expect(throws: Never.self) { _ = try pairing.readReply(file, keys: ana.withNewAnnounceKey(), now: now) }
    }

    // MARK: - Own card and age

    @Test func ownCardIsRefused() throws {
        let file = try invitation()
        expectError(.pairingOwnCard) { _ = try pairing.readInvitation(file, now: now, ownDevice: ana.deviceID) }
        let read = try pairing.readInvitation(file, now: now, ownDevice: ben.deviceID)
        expectError(.pairingOwnCard) {
            _ = try pairing.makeReply(to: read, keys: ana, login: "", displayName: "", macName: "", now: now)
        }
    }

    @Test func oldAndFutureInvitationsExpire() throws {
        let file = try invitation()
        let maxAge = TimeInterval(Timeouts.pairingInvitationMaxAge.components.seconds)
        let skew = TimeInterval(Timeouts.shareClockSkew.components.seconds)
        #expect(throws: Never.self) { _ = try pairing.readInvitation(file, now: now.addingTimeInterval(maxAge), ownDevice: ben.deviceID) }
        expectError(.pairingExpired) {
            _ = try pairing.readInvitation(file, now: now.addingTimeInterval(maxAge + 1), ownDevice: ben.deviceID)
        }
        #expect(throws: Never.self) { _ = try pairing.readInvitation(file, now: now.addingTimeInterval(-skew), ownDevice: ben.deviceID) }
        expectError(.pairingExpired) {
            _ = try pairing.readInvitation(file, now: now.addingTimeInterval(-skew - 1), ownDevice: ben.deviceID)
        }
    }

    @Test func theInviterRefusesARepliedInvitationThatExpired() throws {
        let file = try reply(to: try invitation()).file
        let maxAge = TimeInterval(Timeouts.pairingInvitationMaxAge.components.seconds)
        expectError(.pairingExpired) { _ = try pairing.readReply(file, keys: ana, now: now.addingTimeInterval(maxAge + 1)) }
    }

    @Test func aReplyDatedInTheFutureIsRefused() throws {
        let skew = TimeInterval(Timeouts.shareClockSkew.components.seconds)
        let file = try invitation()
        let read = try pairing.readInvitation(file, now: now, ownDevice: ben.deviceID)
        let answer = try pairing.makeReply(
            to: read, keys: ben, login: "", displayName: "", macName: "", now: now.addingTimeInterval(skew + 60)
        )
        expectError(.pairingExpired) { _ = try pairing.readReply(answer.file, keys: ana, now: now) }
    }

    // MARK: - A relay in the chat

    @Test func aRelayThatSwapsTheReplyChangesTheInvitersCode() throws {
        let file = try invitation()
        let honest = try reply(to: file)
        let mallory = TeamDeviceKeys.generate()
        let forged = try reply(to: file, from: mallory)
        let seenByAna = try pairing.readReply(forged.file, keys: ana, now: now)
        #expect(seenByAna.code != honest.code)
        #expect(seenByAna.teammate.deviceID == mallory.deviceID)
    }

    @Test func aRelayThatSwapsTheInvitationChangesTheRepliersCode() throws {
        let mallory = TeamDeviceKeys.generate()
        let fromAna = try invitation()
        let fromMallory = try invitation(from: mallory)
        // Ben answers Mallory's invitation; Mallory answers Ana's. The codes never match.
        let bensReply = try reply(to: fromMallory)
        let mallorysReply = try reply(to: fromAna, from: mallory)
        let seenByAna = try pairing.readReply(mallorysReply.file, keys: ana, now: now)
        #expect(seenByAna.code != bensReply.code)
    }

    @Test func everyReplyDrawsAFreshNonceAndCode() throws {
        let file = try invitation()
        #expect(try reply(to: file).code != (try reply(to: file).code))
    }

    // MARK: - Sizes and names

    @Test func namesAreSanitizedAndFilesStayWithinTheirBound() throws {
        let long = String(repeating: "é", count: 200)
        let file = try pairing.makeInvitation(keys: ana, login: long, displayName: "Ana\u{202E}\u{0007}  ", macName: long, now: now)
        let read = try pairing.readInvitation(file, now: now, ownDevice: ben.deviceID)
        #expect(read.inviter.displayName == "Ana")
        #expect(read.inviter.login.utf8.count <= TeamProtocol.maxCardStringBytes)
        let answer = try pairing.makeReply(to: read, keys: ben, login: long, displayName: long, macName: long, now: now)
        #expect(answer.file.count <= Limits.maxPairingCardFileBytes)
        let received = try pairing.readReply(answer.file, keys: ana, now: now)
        #expect(received.teammate.macName.utf8.count <= TeamProtocol.maxCardStringBytes)
    }

    @Test func oversizedFilesAreRefusedBeforeParsing() throws {
        var file = try invitation()
        file.append(Data(count: Limits.maxPairingCardFileBytes))
        expectError(.invalidPairingCard) { _ = try RemotePairing.kind(of: file) }
        expectError(.invalidPairingCard) { _ = try pairing.readInvitation(file, now: now, ownDevice: ben.deviceID) }
    }

    @Test func aCardWithAnOversizedNameIsRefused() throws {
        // A card claiming a 64-byte name (one more than a card may carry), signed correctly.
        let name = String(repeating: "a", count: TeamProtocol.maxCardStringBytes + 1)
        let wire = TeamPublicCardModel.encode(
            deviceID: ana.deviceID,
            signingPublicKey: ana.signingPublicKey,
            agreementPublicKey: ana.agreementPublicKey,
            names: [name, "", ""]
        )
        var signed = wire
        signed.appendBigEndian(RemotePairing.seconds(now))
        signed.append(Data(count: Limits.pairingNonceBytes))
        var file = Data(RemotePairingProtocol.magic) + Data([RemotePairingProtocol.version, RemotePairingFileKind.invitation.rawValue])
        file.append(signed)
        file.append(try ana.sign(RemotePairing.invitationMessage(signed)))
        expectError(.invalidPairingCard) { _ = try pairing.readInvitation(file, now: now, ownDevice: ben.deviceID) }
    }
}
