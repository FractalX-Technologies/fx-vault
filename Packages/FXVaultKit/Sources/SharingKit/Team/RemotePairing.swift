import CryptoKit
import Foundation
import VaultCore

/// A teammate card without the announce key (v0.9.0, remote pairing): what crosses a chat or
/// mail in a `.fxvcard` file. The announce key seeds a device's pseudonyms and is known only to
/// its teammates (SHARING-PROTOCOL.md §10.2), so it never travels in the clear.
///
/// Wire form (``encoded()``): `deviceID(16) ‖ signingPK(32) ‖ agreementPK(32) ‖ u16 ‖ login ‖
/// u16 ‖ displayName ‖ u16 ‖ macName`. The names are what the other person typed or their Mac
/// reports: unverified, sanitized, shown as they are.
public struct TeamPublicCardModel: Sendable, Hashable {
    public let deviceID: TeamDeviceID
    /// Ed25519 public key.
    public let signingPublicKey: Data
    /// X25519 public key.
    public let agreementPublicKey: Data
    public let login: String
    public let displayName: String
    public let macName: String
    /// The exact bytes this card was read from, or ``encoded()`` for a card made here. Signatures
    /// and the code cover these bytes.
    let wire: Data

    init(keys: TeamDeviceKeys, login: String, displayName: String, macName: String) {
        deviceID = keys.deviceID
        signingPublicKey = keys.signingPublicKey
        agreementPublicKey = keys.agreementPublicKey
        self.login = DisplayNameSanitizer.sanitize(login)
        self.displayName = DisplayNameSanitizer.sanitize(displayName)
        self.macName = DisplayNameSanitizer.sanitize(macName)
        wire = Self.encode(
            deviceID: deviceID,
            signingPublicKey: signingPublicKey,
            agreementPublicKey: agreementPublicKey,
            names: [self.login, self.displayName, self.macName]
        )
    }

    private init(
        deviceID: TeamDeviceID,
        signingPublicKey: Data,
        agreementPublicKey: Data,
        names: [String],
        wire: Data
    ) {
        self.deviceID = deviceID
        self.signingPublicKey = signingPublicKey
        self.agreementPublicKey = agreementPublicKey
        login = DisplayNameSanitizer.sanitize(names[0])
        displayName = DisplayNameSanitizer.sanitize(names[1])
        macName = DisplayNameSanitizer.sanitize(names[2])
        self.wire = wire
    }

    /// The name to show: the display name, else the login, else the Mac name.
    public var name: String {
        [displayName, login, macName].first { !$0.isEmpty } ?? deviceID.hex
    }

    /// The card's bytes.
    public func encoded() -> Data {
        wire
    }

    /// The full teammate card once the announce key is known (a reply's sealed key, a teammates
    /// file or a nearby card update).
    public func withAnnounceKey(_ announceKey: Data) throws(ShareError) -> TeamCardModel {
        try TeamCardModel(
            deviceID: deviceID,
            signingPublicKey: signingPublicKey,
            agreementPublicKey: agreementPublicKey,
            announceKey: announceKey,
            login: login,
            displayName: displayName,
            macName: macName
        )
    }

    /// Verifies an Ed25519 signature by this card's device.
    func isValidSignature(_ signature: Data, for message: Data) -> Bool {
        guard signature.count == TeamProtocol.signatureBytes,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }

    static func encode(deviceID: TeamDeviceID, signingPublicKey: Data, agreementPublicKey: Data, names: [String]) -> Data {
        var data = Data(deviceID.bytes)
        data.append(signingPublicKey)
        data.append(agreementPublicKey)
        for text in names {
            let bytes = Data(text.utf8)
            data.appendBigEndian(UInt16(bytes.count))
            data.append(bytes)
        }
        return data
    }

    /// Reads a card from `reader`: sizes, UTF-8, keys that parse and an id derived from them.
    static func read(from reader: inout NearbyByteReader) throws(ShareError) -> TeamPublicCardModel {
        do {
            let start = reader.remaining()
            guard let deviceID = TeamDeviceID(bytes: try reader.bytes(TeamProtocol.deviceIDBytes)) else {
                throw ShareError.invalidPairingCard
            }
            let signingPublicKey = try reader.bytes(TeamProtocol.keyBytes)
            let agreementPublicKey = try reader.bytes(TeamProtocol.keyBytes)
            var names: [String] = []
            for _ in 0..<3 {
                let length = Int(try reader.uint16())
                guard length <= TeamProtocol.maxCardStringBytes,
                      let text = String(data: try reader.bytes(length), encoding: .utf8)
                else { throw ShareError.invalidPairingCard }
                names.append(text)
            }
            let wire = start.prefix(start.count - reader.remaining().count)
            guard TeamDeviceID.derive(signingPublicKey: signingPublicKey, agreementPublicKey: agreementPublicKey) == deviceID,
                  (try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)) != nil,
                  (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementPublicKey)) != nil
            else { throw ShareError.invalidPairingCard }
            return TeamPublicCardModel(
                deviceID: deviceID,
                signingPublicKey: signingPublicKey,
                agreementPublicKey: agreementPublicKey,
                names: names,
                wire: Data(wire)
            )
        } catch {
            throw .invalidPairingCard
        }
    }
}

/// The code two people compare on a call to finish remote pairing: six words from the share
/// wordlist (about 77.5 bits).
public struct RemotePairingCodeModel: Sendable, Hashable {
    public let words: [String]

    /// The words joined like a passphrase (`word-word-…`).
    public var text: String {
        words.joined(separator: PassphraseGenerator.separator)
    }
}

/// A teammate invitation read by the person invited (step 1, on B's Mac).
public struct RemoteInvitationModel: Sendable, Hashable {
    /// The inviter.
    public let inviter: TeamPublicCardModel
    public let createdAt: Date
    let nonce: Data
    /// The whole invitation file, echoed in the reply.
    let file: Data
}

/// A reply written by the person invited (step 2, on B's Mac): the file to send back and the
/// code to compare.
public struct RemotePairingReplyFileModel: Sendable, Hashable {
    /// The `.fxvcard` reply. Send it to the inviter.
    public let file: Data
    /// The inviter, to store once the codes match. Their announce key arrives later (in their
    /// first teammates file, or with a card update the first time the two Macs meet nearby).
    public let inviter: TeamPublicCardModel
    public let code: RemotePairingCodeModel
}

/// A reply read by the inviter (step 3, on A's Mac).
public struct RemotePairingReplyModel: Sendable, Hashable {
    /// The new teammate, with the announce key their reply sealed for this Mac.
    public let teammate: TeamCardModel
    public let code: RemotePairingCodeModel
    public let createdAt: Date
}

/// Remote pairing by `.fxvcard` files (v0.9.0, P4).
///
/// 1. A: ``makeInvitation(keys:login:displayName:macName:now:)`` → send the file to B.
/// 2. B: ``readInvitation(_:now:ownDevice:)``, then ``makeReply(to:keys:login:displayName:macName:now:)``
///    → send the reply to A; B sees the code.
/// 3. A: ``readReply(_:keys:now:)`` → A sees the code.
/// 4. Both compare the code on a call and confirm; each Mac then stores the other.
///
/// The code covers both cards and both nonces. B's nonce is drawn after the invitation B holds
/// is fixed, so a relay that swapped the cards would have to find a reply whose code equals one
/// that is already fixed: a second preimage of about 77.5 bits, not a birthday collision.
///
/// Every failure is ``ShareError/invalidPairingCard``, except ``ShareError/pairingExpired`` (an
/// invitation older than ``Timeouts/pairingInvitationMaxAge`` or a file dated in the future) and
/// ``ShareError/pairingOwnCard`` (this Mac's own card).
public struct RemotePairing: Sendable {
    private let wordlist: PassphraseGenerator

    /// Remote pairing over `wordlist` (tests; production uses ``bundled()``).
    init(wordlist: PassphraseGenerator) {
        self.wordlist = wordlist
    }

    /// Remote pairing over the bundled, verified share wordlist.
    public static func bundled() throws(ShareError) -> RemotePairing {
        RemotePairing(wordlist: try PassphraseGenerator.bundled())
    }

    /// What `file` claims to be, from its header only (to route an opened `.fxvcard`).
    public static func kind(of file: Data) throws(ShareError) -> RemotePairingFileKind {
        guard file.count <= Limits.maxPairingCardFileBytes,
              file.count > RemotePairingProtocol.headerBytes,
              file.prefix(RemotePairingProtocol.magic.count) == Data(RemotePairingProtocol.magic),
              file[file.startIndex + RemotePairingProtocol.magic.count] == RemotePairingProtocol.version,
              let kind = RemotePairingFileKind(rawValue: file[file.startIndex + RemotePairingProtocol.magic.count + 1])
        else { throw .invalidPairingCard }
        return kind
    }

    // MARK: - Step 1: invitation

    /// A new invitation from this Mac.
    public func makeInvitation(
        keys: TeamDeviceKeys,
        login: String,
        displayName: String,
        macName: String,
        now: Date
    ) throws(ShareError) -> Data {
        var generator = SystemRandomNumberGenerator()
        return try makeInvitation(
            keys: keys,
            login: login,
            displayName: displayName,
            macName: macName,
            now: now,
            using: &generator
        )
    }

    func makeInvitation(
        keys: TeamDeviceKeys,
        login: String,
        displayName: String,
        macName: String,
        now: Date,
        using generator: inout some RandomNumberGenerator
    ) throws(ShareError) -> Data {
        let card = TeamPublicCardModel(keys: keys, login: login, displayName: displayName, macName: macName)
        let nonce = Self.random(Limits.pairingNonceBytes, using: &generator)
        let signed = Self.invitationSigned(card: card, createdAt: Self.seconds(now), nonce: nonce)
        var file = Self.header(.invitation)
        file.append(signed)
        file.append(try Self.sign(Self.invitationMessage(signed), with: keys))
        return file
    }

    /// Reads an invitation on the invited Mac: format, card, signature, own card, then age.
    public func readInvitation(_ file: Data, now: Date, ownDevice: TeamDeviceID) throws(ShareError) -> RemoteInvitationModel {
        guard try Self.kind(of: file) == .invitation else { throw .invalidPairingCard }
        var reader = NearbyByteReader(file.dropFirst(RemotePairingProtocol.headerBytes))
        let invitation = try Self.readInvitationBody(&reader, file: file)
        do { try reader.requireEnd() } catch { throw .invalidPairingCard }
        guard invitation.inviter.deviceID != ownDevice else { throw .pairingOwnCard }
        try Self.checkAge(of: invitation, now: now)
        return invitation
    }

    // MARK: - Step 2: reply

    /// The reply to `invitation` from this Mac, with the code both people will compare.
    public func makeReply(
        to invitation: RemoteInvitationModel,
        keys: TeamDeviceKeys,
        login: String,
        displayName: String,
        macName: String,
        now: Date
    ) throws(ShareError) -> RemotePairingReplyFileModel {
        var generator = SystemRandomNumberGenerator()
        return try makeReply(
            to: invitation,
            keys: keys,
            login: login,
            displayName: displayName,
            macName: macName,
            now: now,
            using: &generator
        )
    }

    func makeReply(
        to invitation: RemoteInvitationModel,
        keys: TeamDeviceKeys,
        login: String,
        displayName: String,
        macName: String,
        now: Date,
        using generator: inout some RandomNumberGenerator
    ) throws(ShareError) -> RemotePairingReplyFileModel {
        guard invitation.inviter.deviceID != keys.deviceID else { throw .pairingOwnCard }
        let card = TeamPublicCardModel(keys: keys, login: login, displayName: displayName, macName: macName)
        let nonce = Self.random(Limits.pairingNonceBytes, using: &generator)
        let sealed = try Self.sealAnnounceKey(keys.announceKey, invitation: invitation, replier: card.deviceID)
        var body = Data()
        body.appendBigEndian(UInt32(invitation.file.count))
        body.append(invitation.file)
        body.append(card.wire)
        body.appendBigEndian(Self.seconds(now))
        body.append(nonce)
        body.append(sealed.encapsulatedKey)
        body.append(sealed.ciphertext)
        var file = Self.header(.reply)
        file.append(body)
        file.append(try Self.sign(Self.replyMessage(body), with: keys))
        guard file.count <= Limits.maxPairingCardFileBytes else { throw .invalidPairingCard }
        return RemotePairingReplyFileModel(
            file: file,
            inviter: invitation.inviter,
            code: try code(inviter: invitation.inviter, inviterNonce: invitation.nonce, replier: card, replierNonce: nonce)
        )
    }

    // MARK: - Step 3: the inviter reads the reply

    /// Reads a reply on the inviting Mac. The echoed invitation must be this Mac's own (signed by
    /// `keys`) and still valid; the reply must be signed by the replier and its announce key must
    /// open with this Mac's agreement key.
    public func readReply(_ file: Data, keys: TeamDeviceKeys, now: Date) throws(ShareError) -> RemotePairingReplyModel {
        guard try Self.kind(of: file) == .reply,
              file.count > RemotePairingProtocol.headerBytes + TeamProtocol.signatureBytes
        else { throw .invalidPairingCard }
        let body = file.dropFirst(RemotePairingProtocol.headerBytes).dropLast(TeamProtocol.signatureBytes)
        let signature = Data(file.suffix(TeamProtocol.signatureBytes))
        var reader = NearbyByteReader(body)
        let invitation: RemoteInvitationModel
        let card: TeamPublicCardModel
        let createdAt: UInt64
        let nonce: Data
        let encapsulatedKey: Data
        let sealedAnnounce: Data
        do {
            let length = Int(try reader.uint32())
            guard length <= Limits.maxPairingCardFileBytes else { throw ShareError.invalidPairingCard }
            let invitationFile = try reader.bytes(length)
            guard try Self.kind(of: invitationFile) == .invitation else { throw ShareError.invalidPairingCard }
            var invitationReader = NearbyByteReader(invitationFile.dropFirst(RemotePairingProtocol.headerBytes))
            invitation = try Self.readInvitationBody(&invitationReader, file: invitationFile)
            try invitationReader.requireEnd()
            card = try TeamPublicCardModel.read(from: &reader)
            createdAt = try reader.uint64()
            nonce = try reader.bytes(Limits.pairingNonceBytes)
            encapsulatedKey = try reader.bytes(RemotePairingProtocol.encapsulatedKeyBytes)
            sealedAnnounce = try reader.bytes(RemotePairingProtocol.sealedAnnounceBytes)
            try reader.requireEnd()
        } catch {
            throw .invalidPairingCard
        }
        guard card.isValidSignature(signature, for: Self.replyMessage(Data(body))),
              invitation.inviter.deviceID == keys.deviceID,
              invitation.inviter.signingPublicKey == keys.signingPublicKey,
              invitation.inviter.agreementPublicKey == keys.agreementPublicKey
        else { throw .invalidPairingCard }
        guard card.deviceID != keys.deviceID else { throw .pairingOwnCard }
        try Self.checkAge(of: invitation, now: now)
        guard Self.date(createdAt) <= now.addingTimeInterval(Self.timeInterval(Timeouts.shareClockSkew)) else {
            throw .pairingExpired
        }
        let announceKey = try Self.openAnnounceKey(
            encapsulatedKey: encapsulatedKey,
            ciphertext: sealedAnnounce,
            invitation: invitation,
            replier: card.deviceID,
            agreement: keys.agreement
        )
        return RemotePairingReplyModel(
            teammate: try card.withAnnounceKey(announceKey),
            code: try code(inviter: invitation.inviter, inviterNonce: invitation.nonce, replier: card, replierNonce: nonce),
            createdAt: Self.date(createdAt)
        )
    }

    // MARK: - Code

    /// `HKDF-SHA256(ikm: LP(code label) ‖ LP(card_A ‖ nonce_A) ‖ LP(card_B ‖ nonce_B), salt: empty,
    /// info: code-words label, 128 bytes)`, read as big-endian u16 values; a value below the largest
    /// multiple of the word count that fits in 16 bits picks `words[v % count]` (no bias).
    func code(
        inviter: TeamPublicCardModel,
        inviterNonce: Data,
        replier: TeamPublicCardModel,
        replierNonce: Data
    ) throws(ShareError) -> RemotePairingCodeModel {
        var transcript = Data()
        transcript.appendLengthPrefixed(RemotePairingProtocol.codeLabel)
        transcript.appendLengthPrefixed(inviter.wire + inviterNonce)
        transcript.appendLengthPrefixed(replier.wire + replierNonce)
        let stream = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: transcript),
            salt: Data(),
            info: RemotePairingProtocol.codeWordsInfo,
            outputByteCount: RemotePairingProtocol.codeStreamBytes
        ).withUnsafeBytes { Data($0) }
        let count = wordlist.words.count
        let bound = (Int(UInt16.max) + 1) / count * count
        var words: [String] = []
        var offset = 0
        while words.count < RemotePairingProtocol.codeWordCount {
            guard let value = stream.readBigEndian(UInt16.self, at: offset) else { throw .invalidPairingCard }
            offset += MemoryLayout<UInt16>.size
            if Int(value) < bound {
                words.append(wordlist.words[Int(value) % count])
            }
        }
        return RemotePairingCodeModel(words: words)
    }

    // MARK: - Private

    private static func header(_ kind: RemotePairingFileKind) -> Data {
        var data = Data(RemotePairingProtocol.magic)
        data.append(RemotePairingProtocol.version)
        data.append(kind.rawValue)
        return data
    }

    /// `publicCard ‖ u64 createdAt ‖ nonce`: what the inviter signs (after its label).
    static func invitationSigned(card: TeamPublicCardModel, createdAt: UInt64, nonce: Data) -> Data {
        var data = card.wire
        data.appendBigEndian(createdAt)
        data.append(nonce)
        return data
    }

    static func invitationMessage(_ signed: Data) -> Data {
        var message = Data()
        message.appendLengthPrefixed(RemotePairingProtocol.invitationSignatureLabel)
        message.appendLengthPrefixed(signed)
        return message
    }

    static func replyMessage(_ body: Data) -> Data {
        var message = Data()
        message.appendLengthPrefixed(RemotePairingProtocol.replySignatureLabel)
        message.appendLengthPrefixed(body)
        return message
    }

    /// `LP(announce label) ‖ SHA256(invitation file) ‖ deviceID_B`.
    static func announceInfo(invitation: RemoteInvitationModel, replier: TeamDeviceID) -> Data {
        var info = Data()
        info.appendLengthPrefixed(RemotePairingProtocol.announceLabel)
        info.append(Data(SHA256.hash(data: invitation.file)))
        info.append(replier.bytes)
        return info
    }

    /// Reads `publicCard ‖ createdAt ‖ nonce ‖ signature` and checks the signature.
    private static func readInvitationBody(
        _ reader: inout NearbyByteReader,
        file: Data
    ) throws(ShareError) -> RemoteInvitationModel {
        let start = reader.remaining()
        let card = try TeamPublicCardModel.read(from: &reader)
        let createdAt: UInt64
        let nonce: Data
        let signature: Data
        do {
            createdAt = try reader.uint64()
            nonce = try reader.bytes(Limits.pairingNonceBytes)
            signature = try reader.bytes(TeamProtocol.signatureBytes)
        } catch {
            throw .invalidPairingCard
        }
        let signed = start.prefix(start.count - reader.remaining().count - TeamProtocol.signatureBytes)
        guard card.isValidSignature(signature, for: invitationMessage(Data(signed))) else { throw .invalidPairingCard }
        return RemoteInvitationModel(inviter: card, createdAt: date(createdAt), nonce: nonce, file: Data(file))
    }

    private static func checkAge(of invitation: RemoteInvitationModel, now: Date) throws(ShareError) {
        let skew = timeInterval(Timeouts.shareClockSkew)
        guard invitation.createdAt <= now.addingTimeInterval(skew),
              now.timeIntervalSince(invitation.createdAt) <= timeInterval(Timeouts.pairingInvitationMaxAge)
        else { throw .pairingExpired }
    }

    private static func sealAnnounceKey(
        _ announceKey: Data,
        invitation: RemoteInvitationModel,
        replier: TeamDeviceID
    ) throws(ShareError) -> (encapsulatedKey: Data, ciphertext: Data) {
        do {
            let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: invitation.inviter.agreementPublicKey)
            var sender = try HPKE.Sender(
                recipientKey: recipient,
                ciphersuite: RemotePairingProtocol.sealSuite,
                info: announceInfo(invitation: invitation, replier: replier)
            )
            let ciphertext = try sender.seal(announceKey)
            return (sender.encapsulatedKey, ciphertext)
        } catch {
            throw .encryptionFailed
        }
    }

    private static func openAnnounceKey(
        encapsulatedKey: Data,
        ciphertext: Data,
        invitation: RemoteInvitationModel,
        replier: TeamDeviceID,
        agreement: Curve25519.KeyAgreement.PrivateKey
    ) throws(ShareError) -> Data {
        do {
            var recipient = try HPKE.Recipient(
                privateKey: agreement,
                ciphersuite: RemotePairingProtocol.sealSuite,
                info: announceInfo(invitation: invitation, replier: replier),
                encapsulatedKey: encapsulatedKey
            )
            let key = try recipient.open(ciphertext)
            guard key.count == TeamProtocol.announceKeyBytes else { throw ShareError.invalidPairingCard }
            return key
        } catch {
            throw .invalidPairingCard
        }
    }

    private static func sign(_ message: Data, with keys: TeamDeviceKeys) throws(ShareError) -> Data {
        do {
            return try keys.sign(message)
        } catch {
            throw .encryptionFailed
        }
    }

    private static func random(_ count: Int, using generator: inout some RandomNumberGenerator) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// Whole seconds since 1970 (a date before 1970 is written as 0).
    static func seconds(_ date: Date) -> UInt64 {
        UInt64(max(0, date.timeIntervalSince1970.rounded(.down)))
    }

    private static func date(_ seconds: UInt64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func timeInterval(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds)
    }
}
