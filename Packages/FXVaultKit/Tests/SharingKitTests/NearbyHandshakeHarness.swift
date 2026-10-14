import CryptoKit
import Foundation
import Testing
import VaultCore
@testable import SharingKit

/// Drives two ``NearbyHandshake``s by passing frames directly (no transport), recording every
/// frame and event. `interceptToResponder` / `interceptToInitiator` can rewrite or drop frames.
struct HandshakeHarness {
    var initiator: NearbyHandshake
    var responder: NearbyHandshake
    var initiatorEvents: [NearbyEvent] = []
    var responderEvents: [NearbyEvent] = []
    /// Every frame each side produced, in order.
    var initiatorFrames: [Data] = []
    var responderFrames: [Data] = []
    var interceptToResponder: (Data) -> [Data] = { [$0] }
    var interceptToInitiator: (Data) -> [Data] = { [$0] }
    private var toResponder: [Data] = []
    private var toInitiator: [Data] = []

    init(initiator: NearbyHandshake, responder: NearbyHandshake) {
        self.initiator = initiator
        self.responder = responder
    }

    /// The KAT parties: fixed keys and nonces, names "Alice's Mac" / "Bob's Mac".
    static func kat() throws -> HandshakeHarness {
        let kat = try NearbyKAT.load()
        return HandshakeHarness(
            initiator: NearbyHandshake(
                role: .initiator,
                localName: kat.inputs.nameI,
                keyMaterial: try kat.keyMaterial(.initiator)
            ),
            responder: NearbyHandshake(
                role: .responder,
                localName: kat.inputs.nameR,
                keyMaterial: try kat.keyMaterial(.responder)
            )
        )
    }

    mutating func recordInitiator(_ step: NearbyStep) {
        initiatorEvents += step.events
        initiatorFrames += step.frames
        for frame in step.frames {
            toResponder += interceptToResponder(frame)
        }
    }

    mutating func recordResponder(_ step: NearbyStep) {
        responderEvents += step.events
        responderFrames += step.frames
        for frame in step.frames {
            toInitiator += interceptToInitiator(frame)
        }
    }

    /// Delivers queued frames until both directions are empty.
    mutating func pump() {
        while !toResponder.isEmpty || !toInitiator.isEmpty {
            if !toResponder.isEmpty {
                let frame = toResponder.removeFirst()
                recordResponder(responder.receive(frame))
            }
            if !toInitiator.isEmpty {
                let frame = toInitiator.removeFirst()
                recordInitiator(initiator.receive(frame))
            }
        }
    }

    /// Delivers one frame straight to a side (bypasses interception and queues).
    mutating func inject(toResponder frame: Data) {
        recordResponder(responder.receive(frame))
        pump()
    }

    mutating func inject(toInitiator frame: Data) {
        recordInitiator(initiator.receive(frame))
        pump()
    }

    /// Starts both sides and runs HELLO/HELLO/REVEAL.
    mutating func runHandshake() throws {
        recordResponder(try responder.start())
        recordInitiator(try initiator.start())
        pump()
    }

    /// Handshake plus both confirmations.
    mutating func runToReadyForManifest() throws {
        try runHandshake()
        recordInitiator(try initiator.confirmSAS())
        recordResponder(try responder.confirmSAS())
        pump()
    }

    /// Through the manifest.
    mutating func runToManifest(_ package: SharePackageModel) throws {
        try runToReadyForManifest()
        recordInitiator(try initiator.sendManifest(package))
        pump()
    }

    /// Encrypted frames the initiator produced so far, which is its next sequence number.
    /// Encrypted frames start with the version byte 0x01, as does HELLO_I (type 0x01).
    var initiatorEncryptedCount: UInt64 {
        UInt64(initiatorFrames.filter { $0.first == NearbyProtocol.maxVersion }.count - 1)
    }

    var initiatorAbort: NearbyAbortModel? {
        initiatorEvents.compactMap(\.abortModel).first
    }

    var responderAbort: NearbyAbortModel? {
        responderEvents.compactMap(\.abortModel).first
    }

    /// The received manifest (responder).
    var receivedManifest: SharePackageModel? {
        for event in responderEvents {
            if case .manifestReceived(let package) = event { return package }
        }
        return nil
    }

    /// The received payload (responder).
    var receivedPayload: SharePackageModel? {
        for event in responderEvents {
            if case .payloadReceived(let package) = event { return package }
        }
        return nil
    }
}

/// Seals frames with the KAT direction keys, to forge protocol violations.
struct KATForger {
    let initiatorToResponder: SymmetricKey
    let responderToInitiator: SymmetricKey

    init() throws {
        let kat = try NearbyKAT.load()
        initiatorToResponder = SymmetricKey(data: try kat.bytes(try kat.output("k_i2r")))
        responderToInitiator = SymmetricKey(data: try kat.bytes(try kat.output("k_r2i")))
    }

    func fromInitiator(_ type: NearbyMessageType, sequence: UInt64, body: Data) throws -> Data {
        try NearbyEncryptedFrame.seal(type: type, sequence: sequence, body: body, key: initiatorToResponder)
    }

    func fromResponder(_ type: NearbyMessageType, sequence: UInt64, body: Data) throws -> Data {
        try NearbyEncryptedFrame.seal(type: type, sequence: sequence, body: body, key: responderToInitiator)
    }
}
