import CryptoKit
import Foundation
import VaultCore

/// One side's ephemeral handshake secrets: an X25519 key pair and a 32-byte nonce.
/// Fresh for every session; never stored.
public struct NearbyKeyMaterial: Sendable {
    let privateKey: Curve25519.KeyAgreement.PrivateKey // gitleaks:allow (type declaration, no key material)
    let nonce: Data

    /// Fixed material for known-answer tests.
    init(privateKey: Curve25519.KeyAgreement.PrivateKey, nonce: Data) {
        self.privateKey = privateKey
        self.nonce = nonce
    }

    /// New random material (CryptoKit key generation and `SystemRandomNumberGenerator`).
    public static func random() -> NearbyKeyMaterial {
        var generator = SystemRandomNumberGenerator()
        let nonce = Data((0..<NearbyProtocol.nonceBytes).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
        return NearbyKeyMaterial(privateKey: Curve25519.KeyAgreement.PrivateKey(), nonce: nonce)
    }

    /// The raw public key.
    var publicKey: Data {
        privateKey.publicKey.rawRepresentation
    }
}

/// Everything the transcript hash binds (§9.4 step 4). Names are the exact wire bytes.
struct NearbyTranscriptModel: Sendable, Hashable {
    var maxVersionI: UInt8
    var maxVersionR: UInt8
    var version: UInt8
    var suiteI: UInt8
    var suiteR: UInt8
    var commitment: Data
    var publicKeyI: Data
    var nonceI: Data
    var nameI: Data
    var publicKeyR: Data
    var nonceR: Data
    var nameR: Data
}

/// The per-session secrets derived after the key agreement.
struct NearbySessionKeys: Sendable {
    let sasValue: UInt64
    let initiatorToResponder: SymmetricKey
    let responderToInitiator: SymmetricKey

    /// The key this role seals with.
    func sendingKey(for role: NearbyRole) -> SymmetricKey {
        role == .initiator ? initiatorToResponder : responderToInitiator
    }

    /// The key this role opens with.
    func receivingKey(for role: NearbyRole) -> SymmetricKey {
        role == .initiator ? responderToInitiator : initiatorToResponder
    }
}

/// An internal error carrying the abort reason.
struct NearbyFailure: Error, Sendable, Hashable {
    let reason: NearbyAbortReason

    init(_ reason: NearbyAbortReason) {
        self.reason = reason
    }
}

/// The pure cryptography of nearby protocol v1 (§9.4, D21), shared by share and chat. Every
/// function takes the purpose's ``NearbyLabels``; the default is the share labels.
enum NearbyCrypto {
    /// `C = SHA256(LP("<prefix>/commit") ‖ maxVerI ‖ suiteI ‖ LP(pkI) ‖ LP(nI))`.
    static func commitment(
        maxVersion: UInt8,
        suite: UInt8,
        publicKey: Data,
        nonce: Data,
        labels: NearbyLabels = .share
    ) -> Data {
        var message = Data()
        message.appendLengthPrefixed(labels.commit)
        message.append(maxVersion)
        message.append(suite)
        message.appendLengthPrefixed(publicKey)
        message.appendLengthPrefixed(nonce)
        return Data(SHA256.hash(data: message))
    }

    /// `TH = SHA256(LP("<prefix>/transcript") ‖ maxVerI ‖ maxVerR ‖ ver ‖ suiteI ‖ suiteR ‖ LP(C) ‖
    /// LP(pkI) ‖ LP(nI) ‖ LP(nameI) ‖ LP(pkR) ‖ LP(nR) ‖ LP(nameR))`.
    static func transcriptHash(_ transcript: NearbyTranscriptModel, labels: NearbyLabels = .share) -> Data {
        var message = Data()
        message.appendLengthPrefixed(labels.transcript)
        message.append(contentsOf: [
            transcript.maxVersionI,
            transcript.maxVersionR,
            transcript.version,
            transcript.suiteI,
            transcript.suiteR,
        ])
        for field in [
            transcript.commitment,
            transcript.publicKeyI,
            transcript.nonceI,
            transcript.nameI,
            transcript.publicKeyR,
            transcript.nonceR,
            transcript.nameR,
        ] {
            message.appendLengthPrefixed(field)
        }
        return Data(SHA256.hash(data: message))
    }

    /// X25519 with the peer's raw public key. CryptoKit rejects low-order points; an all-zero
    /// result is rejected as well.
    static func sharedSecret(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data
    ) throws(NearbyFailure) -> SharedSecret {
        guard peerPublicKey.count == NearbyProtocol.publicKeyBytes else {
            throw NearbyFailure(.invalidKey)
        }
        let secret: SharedSecret
        do {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
            secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        } catch {
            throw NearbyFailure(.invalidKey)
        }
        let isAllZero = secret.withUnsafeBytes { bytes in bytes.allSatisfy { $0 == 0 } }
        guard !isAllZero else { throw NearbyFailure(.invalidKey) }
        return secret
    }

    /// SAS and direction keys from the shared secret, salted with the transcript hash.
    static func deriveSession(
        sharedSecret: SharedSecret,
        transcriptHash: Data,
        labels: NearbyLabels = .share
    ) -> NearbySessionKeys {
        let sasKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: labels.sas,
            outputByteCount: NearbyProtocol.sasKeyBytes
        )
        let sasBits = sasKey.withUnsafeBytes { bytes in
            bytes.reduce(UInt64.zero) { ($0 << UInt8.bitWidth) | UInt64($1) }
        }
        let initiatorToResponder = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: labels.initiatorToResponder,
            outputByteCount: NearbyProtocol.directionKeyBytes
        )
        let responderToInitiator = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcriptHash,
            sharedInfo: labels.responderToInitiator,
            outputByteCount: NearbyProtocol.directionKeyBytes
        )
        return NearbySessionKeys(
            sasValue: sasBits % NearbyProtocol.sasModulus,
            initiatorToResponder: initiatorToResponder,
            responderToInitiator: responderToInitiator
        )
    }
}
