import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// Known-answer tests for remote pairing (v0.9.0) against Fixtures/pairing_kat.json, generated
/// by Fixtures/kat/pairing_kat.py from RFC 8032, RFC 5869, RFC 7748 and RFC 9180. Ed25519
/// signatures there are deterministic and the HPKE seal uses a random ephemeral; CryptoKit signs
/// with randomness, so Swift verifies the signatures and opens the seal, and reproduces the
/// cards, the signed bytes, the HPKE info, the code stream and the code byte for byte.
@Suite("Remote pairing known-answer vectors")
struct RemotePairingKATTests {
    struct Document: Decodable {
        let inputs: [String: Input]
        let outputs: [String: String]

        enum Input: Decodable {
            case text(String)
            case number(Int64)

            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int64.self) {
                    self = .number(number)
                } else {
                    self = .text(try container.decode(String.self))
                }
            }
        }

        static func load() throws -> Document {
            try JSONDecoder().decode(Document.self, from: Fixtures.data("pairing_kat.json"))
        }

        func text(_ key: String) throws -> String {
            guard case .text(let text) = try #require(inputs[key]) else { throw KATError.wrongType }
            return text
        }

        func date(_ key: String) throws -> Date {
            guard case .number(let number) = try #require(inputs[key]) else { throw KATError.wrongType }
            return Date(timeIntervalSince1970: TimeInterval(number))
        }

        func bytes(_ key: String) throws -> Data {
            try #require(Data(hex: try text(key)))
        }

        func string(_ key: String) throws -> String {
            try #require(outputs[key])
        }

        func output(_ key: String) throws -> Data {
            try #require(Data(hex: try string(key)))
        }

        func device(_ prefix: String) throws -> TeamDeviceKeys {
            TeamDeviceKeys(
                signing: try Curve25519.Signing.PrivateKey(rawRepresentation: try bytes("\(prefix)SigningSeed")),
                agreement: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try bytes("\(prefix)AgreementKey")),
                announceKey: try bytes("\(prefix)AnnounceKey")
            )
        }
    }

    enum KATError: Error {
        case wrongType
    }

    let kat: Document
    let pairing: RemotePairing
    let ana: TeamDeviceKeys
    let ben: TeamDeviceKeys

    init() throws {
        kat = try Document.load()
        pairing = try RemotePairing.bundled()
        ana = try kat.device("ana")
        ben = try kat.device("ben")
    }

    private var anaCard: TeamPublicCardModel {
        TeamPublicCardModel(keys: ana, login: "user-a", displayName: "Ana", macName: "Ana's Mac")
    }

    private var benCard: TeamPublicCardModel {
        TeamPublicCardModel(keys: ben, login: "user-b", displayName: "Ben", macName: "Ben's Mac")
    }

    @Test func labelsArePinned() throws {
        #expect(try kat.text("labelPrefix") == RemotePairingProtocol.labelPrefix)
        let python = try String(contentsOf: Fixtures.url("kat/pairing_kat.py"), encoding: .utf8)
        #expect(python.contains("PREFIX = b'\(RemotePairingProtocol.labelPrefix)'"))
        #expect(python.contains("0x46, 0x58, 0x56, 0x43, 0x41, 0x52, 0x44, 0x1A"))
    }

    @Test func publicCardsMatchByteForByte() throws {
        #expect(anaCard.encoded() == (try kat.output("publicCardA")))
        #expect(benCard.encoded() == (try kat.output("publicCardB")))
    }

    @Test func theInvitationMatchesAndVerifies() throws {
        let invitation = try kat.output("invitation")
        let signed = RemotePairing.invitationSigned(
            card: anaCard,
            createdAt: RemotePairing.seconds(try kat.date("createdA")),
            nonce: try kat.bytes("nonceA")
        )
        let header = Data(RemotePairingProtocol.magic) + Data([RemotePairingProtocol.version, RemotePairingFileKind.invitation.rawValue])
        #expect(invitation.dropLast(TeamProtocol.signatureBytes) == header + signed)
        let read = try pairing.readInvitation(invitation, now: try kat.date("createdB"), ownDevice: ben.deviceID)
        #expect(read.inviter == anaCard)
        #expect(read.nonce == (try kat.bytes("nonceA")))
        #expect(RemotePairing.announceInfo(invitation: read, replier: ben.deviceID) == (try kat.output("announceInfo")))
    }

    @Test func theReplyOpensWithTheSameCode() throws {
        let reply = try pairing.readReply(try kat.output("reply"), keys: ana, now: try kat.date("createdB"))
        #expect(reply.teammate == ben.card(login: "user-b", displayName: "Ben", macName: "Ben's Mac"))
        #expect(reply.createdAt == (try kat.date("createdB")))
        #expect(reply.code.text == (try kat.string("code")))
    }

    @Test func theCodeStreamAndWordsMatch() throws {
        var transcript = Data()
        transcript.appendLengthPrefixed(RemotePairingProtocol.codeLabel)
        transcript.appendLengthPrefixed(anaCard.encoded() + (try kat.bytes("nonceA")))
        transcript.appendLengthPrefixed(benCard.encoded() + (try kat.bytes("nonceB")))
        let stream = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: transcript),
            salt: Data(),
            info: RemotePairingProtocol.codeWordsInfo,
            outputByteCount: RemotePairingProtocol.codeStreamBytes
        ).withUnsafeBytes { Data($0) }
        #expect(stream == (try kat.output("codeStream")))
        let code = try pairing.code(
            inviter: anaCard,
            inviterNonce: try kat.bytes("nonceA"),
            replier: benCard,
            replierNonce: try kat.bytes("nonceB")
        )
        #expect(code.text == (try kat.string("code")))
    }
}
