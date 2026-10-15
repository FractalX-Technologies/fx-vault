// Reference generator for the FX Vault nearby-share v1 vectors, the nearby-chat v1
// (fxvault-chat/v1) vectors and the .fxvault v1 envelope vector (tasks/todo.md §9.1, §9.4).
// Independent of SharingKit: pure CryptoKit, no transport.
//
// v0.2.0: chat runs the same handshake and frame layout with every label under the prefix
// "fxvault/chat/v1" (share: "fxvault/nearby/v1"); its lines are prefixed "chat_".
//
// Revised for the M6 transcript: C binds maxVerI and suiteI; TH binds maxVerI, maxVerR, ver,
// suiteI AND suiteR, C, both public keys, both nonces and both display names.
//
// This file is a test fixture, not part of any target. Run it with:
//   swiftc -parse-as-library -O NearbyProtocolReference.swift -o /tmp/nearby-ref && /tmp/nearby-ref
// and compare its output line by line with `python3 crosscheck.py --lines` followed by
// `python3 crosscheck.py --chat-lines` (see crosscheck.py).

import CryptoKit
import Foundation

// MARK: - Encoding helpers

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// u32 big-endian length prefix + bytes. Used for every variable-length transcript field.
func lp(_ d: Data) -> Data {
    var n = UInt32(d.count).bigEndian
    return Data(bytes: &n, count: 4) + d
}

func be64(_ v: UInt64) -> Data {
    var b = v.bigEndian
    return Data(bytes: &b, count: 8)
}

func bytes(_ range: ClosedRange<Int>) -> Data { Data(range.map { UInt8($0) }) }

// MARK: - Nearby v1 constants

struct Labels {
    let commit: Data, transcript: Data, sas: Data, i2r: Data, r2i: Data
    init(prefix: String) {
        commit = Data("\(prefix)/commit".utf8)
        transcript = Data("\(prefix)/transcript".utf8)
        sas = Data("\(prefix)/sas".utf8)
        i2r = Data("\(prefix)/key/i2r".utf8)
        r2i = Data("\(prefix)/key/r2i".utf8)
    }
}

enum NearbyV1 {
    static let version: UInt8 = 1
    static let suite: UInt8 = 1 // X25519 + HKDF-SHA256 + AES-256-GCM + SHA-256
    static let share = Labels(prefix: "fxvault/nearby/v1")
    static let chat = Labels(prefix: "fxvault/chat/v1")
}

/// C = SHA-256( LP(label) || maxVerI || suiteI || LP(pkI) || LP(nI) )
func commitment(maxVersionI: UInt8, suiteI: UInt8, pkI: Data, nI: Data, labels: Labels = NearbyV1.share) -> Data {
    var m = lp(labels.commit)
    m.append(maxVersionI)
    m.append(suiteI)
    m += lp(pkI) + lp(nI)
    return Data(SHA256.hash(data: m))
}

struct TranscriptInput {
    var maxVersionI: UInt8, maxVersionR: UInt8, version: UInt8, suiteI: UInt8, suiteR: UInt8
    var commitment: Data
    var pkI: Data, nI: Data, nameI: String
    var pkR: Data, nR: Data, nameR: String
}

/// TH = SHA-256( LP(label) || maxVerI || maxVerR || ver || suiteI || suiteR || LP(C)
///               || LP(pkI) || LP(nI) || LP(nameI) || LP(pkR) || LP(nR) || LP(nameR) )
func transcriptHash(_ t: TranscriptInput, labels: Labels = NearbyV1.share) -> Data {
    var m = lp(labels.transcript)
    m.append(contentsOf: [t.maxVersionI, t.maxVersionR, t.version, t.suiteI, t.suiteR])
    m += lp(t.commitment) + lp(t.pkI) + lp(t.nI) + lp(Data(t.nameI.utf8))
    m += lp(t.pkR) + lp(t.nR) + lp(Data(t.nameR.utf8))
    return Data(SHA256.hash(data: m))
}

struct SessionKeys { let sas: String; let sasValue: UInt64; let i2r: SymmetricKey; let r2i: SymmetricKey }

func deriveSession(shared: SharedSecret, th: Data, labels: Labels = NearbyV1.share) -> SessionKeys {
    let sasKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: th, sharedInfo: labels.sas, outputByteCount: 8)
    let u64 = sasKey.withUnsafeBytes { raw in raw.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
    let value = u64 % 1_000_000
    let digits = String(format: "%06llu", value)
    let display = String(digits.prefix(3)) + " " + String(digits.suffix(3))
    let i2r = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: th, sharedInfo: labels.i2r, outputByteCount: 32)
    let r2i = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: th, sharedInfo: labels.r2i, outputByteCount: 32)
    return SessionKeys(sas: display, sasValue: value, i2r: i2r, r2i: r2i)
}

// MARK: - Encrypted frame: [ver:1][type:1][seq:8 BE][ciphertext][tag:16]; AAD = first 10 bytes; nonce = 0^4 || seq

func sealFrame(type: UInt8, seq: UInt64, plaintext: Data, key: SymmetricKey) throws -> Data {
    var header = Data([NearbyV1.version, type])
    header += be64(seq)
    let nonce = try AES.GCM.Nonce(data: Data(count: 4) + be64(seq))
    let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: header)
    return header + box.ciphertext + box.tag
}

// MARK: - .fxvault v1 header (64 bytes, used as AAD)

func fxvaultHeader(opsLimit: UInt32, memLimitKiB: UInt32, salt: Data, nonce: Data) -> Data {
    var h = Data([0x46, 0x58, 0x56, 0x41, 0x55, 0x4C, 0x54, 0x1A]) // "FXVAULT" + 0x1A
    var v = UInt16(1).bigEndian; h += Data(bytes: &v, count: 2)    // format version
    var l = UInt16(64).bigEndian; h += Data(bytes: &l, count: 2)   // header length
    h.append(1)                                                    // kdf id: Argon2id v1.3
    h.append(1)                                                    // aead id: AES-256-GCM
    var o = opsLimit.bigEndian; h += Data(bytes: &o, count: 4)
    var m = memLimitKiB.bigEndian; h += Data(bytes: &m, count: 4)
    h.append(1)                                                    // parallelism
    h.append(0)                                                    // flags
    h += salt + nonce                                              // 16 + 12 -> offset 52
    h += Data(count: 64 - h.count)                                 // reserved zero
    return h
}

// MARK: - Vectors

@main struct Vectors {
    static func main() throws {
        let skIRaw = bytes(0x00...0x1f), skRRaw = bytes(0x20...0x3f)
        let skI = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: skIRaw)
        let skR = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: skRRaw)
        let nI = bytes(0x40...0x5f), nR = bytes(0x60...0x7f)
        let nameI = "Alice's Mac", nameR = "Bob's Mac"
        let pkI = skI.publicKey.rawRepresentation, pkR = skR.publicKey.rawRepresentation
        let c = commitment(maxVersionI: 1, suiteI: 1, pkI: pkI, nI: nI)
        let t = TranscriptInput(maxVersionI: 1, maxVersionR: 1, version: 1, suiteI: 1, suiteR: 1, commitment: c,
                                pkI: pkI, nI: nI, nameI: nameI, pkR: pkR, nR: nR, nameR: nameR)
        let th = transcriptHash(t)
        let ssI = try skI.sharedSecretFromKeyAgreement(with: skR.publicKey)
        let ssR = try skR.sharedSecretFromKeyAgreement(with: skI.publicKey)
        let kI = deriveSession(shared: ssI, th: th)
        let kR = deriveSession(shared: ssR, th: th)
        precondition(kI.sas == kR.sas)
        let confirmI = try sealFrame(type: 0x10, seq: 0, plaintext: Data([0x01]), key: kI.i2r)
        let confirmR = try sealFrame(type: 0x10, seq: 0, plaintext: Data([0x01]), key: kR.r2i)

        // Negative vectors: any transcript change moves the SAS.
        var altered = t; altered.nameR = "Bob's Mac "
        let kAltered = deriveSession(shared: ssI, th: transcriptHash(altered))
        var higherR = t; higherR.maxVersionR = 2
        let thHigherR = transcriptHash(higherR)

        // .fxvault v1 envelope vector (key injected; Argon2id is checked separately in VaultCrypto).
        let salt = bytes(0x80...0x8f), fileNonce = bytes(0x90...0x9b)
        let header = fxvaultHeader(opsLimit: 3, memLimitKiB: 65536, salt: salt, nonce: fileNonce)
        let fileKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        let payload = Data(#"{"schema":"fxvault.share/1"}"#.utf8)
        let box = try AES.GCM.seal(payload, using: fileKey, nonce: try AES.GCM.Nonce(data: fileNonce), authenticating: header)
        let file = header + box.ciphertext + box.tag

        let lines: [(String, String)] = [
            ("C", c.hex),
            ("CONFIRM_i2r_seq0", confirmI.hex),
            ("CONFIRM_r2i_seq0", confirmR.hex),
            ("SAS", kI.sas),
            ("SAS_altered_nameR", kAltered.sas),
            ("SAS_value", String(kI.sasValue)),
            ("TH", th.hex),
            ("TH_maxVerR_2", thHigherR.hex),
            ("fxvault_ciphertext_and_tag", file.dropFirst(64).hex),
            ("fxvault_file_length", String(file.count)),
            ("fxvault_header", header.hex),
            ("k_i2r", kI.i2r.withUnsafeBytes { Data($0) }.hex),
            ("k_r2i", kI.r2i.withUnsafeBytes { Data($0) }.hex),
            ("pkI", pkI.hex),
            ("pkR", pkR.hex),
            ("shared_secret", ssI.withUnsafeBytes { Data($0) }.hex),
        ]
        for (key, value) in lines { print("\(key)=\(value)") }

        // fxvault-chat/v1: same inputs, chat labels.
        let chatC = commitment(maxVersionI: 1, suiteI: 1, pkI: pkI, nI: nI, labels: NearbyV1.chat)
        precondition(chatC != c)
        var chatT = t; chatT.commitment = chatC
        let chatTH = transcriptHash(chatT, labels: NearbyV1.chat)
        let chatI = deriveSession(shared: ssI, th: chatTH, labels: NearbyV1.chat)
        let chatR = deriveSession(shared: ssR, th: chatTH, labels: NearbyV1.chat)
        precondition(chatI.sas == chatR.sas)
        let shareCommitmentTH = transcriptHash(t, labels: NearbyV1.chat)
        let chatShareCommitment = deriveSession(shared: ssI, th: shareCommitmentTH, labels: NearbyV1.chat)
        let text = Data("Hello from FX Vault".utf8)
        let chatLines: [(String, String)] = [
            ("C", chatC.hex),
            ("CLOSE_i2r_seq2", try sealFrame(type: 0x7E, seq: 2, plaintext: Data(), key: chatI.i2r).hex),
            ("CONFIRM_i2r_seq0", try sealFrame(type: 0x10, seq: 0, plaintext: Data([0x01]), key: chatI.i2r).hex),
            ("CONFIRM_r2i_seq0", try sealFrame(type: 0x10, seq: 0, plaintext: Data([0x01]), key: chatR.r2i).hex),
            ("PING_r2i_seq1", try sealFrame(type: 0x30, seq: 1, plaintext: Data(), key: chatR.r2i).hex),
            ("SAS", chatI.sas),
            ("SAS_value", String(chatI.sasValue)),
            ("SAS_with_share_commitment", chatShareCommitment.sas),
            ("TEXT_i2r_seq1", try sealFrame(type: 0x20, seq: 1, plaintext: text, key: chatI.i2r).hex),
            ("TH", chatTH.hex),
            ("k_i2r", chatI.i2r.withUnsafeBytes { Data($0) }.hex),
            ("k_r2i", chatI.r2i.withUnsafeBytes { Data($0) }.hex),
            ("pkI", pkI.hex),
            ("pkR", pkR.hex),
            ("shared_secret", ssI.withUnsafeBytes { Data($0) }.hex),
        ]
        for (key, value) in chatLines { print("chat_\(key)=\(value)") }
    }
}
