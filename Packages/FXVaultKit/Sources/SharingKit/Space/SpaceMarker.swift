import CryptoKit
import Foundation
import VaultCore

/// The `FXVAULT_SPACE` variable of a shared scope (S4): which version GitHub holds, or which one
/// a member is publishing, signed by that member's device.
///
/// JSON with sorted keys: `{"at","by","dev","f","head","sig","space","state","v"}`. `published`:
/// `v` is the head version and `head` its hash. `publishing`: `v` is the version being pushed and
/// `head` the hash of its parent (the head it builds on). `at` is for display only; order comes
/// from `v` and `head`. The signature covers `LP(marker label) ‖ spaceID ‖ u64 v ‖ u8 state ‖
/// LP(head) ‖ LP(dev) ‖ LP(at) ‖ LP(by)`.
public struct SpaceMarkerModel: Sendable, Hashable {
    public enum State: String, Sendable, Hashable, Codable {
        case publishing
        case published
    }

    public let spaceID: SpaceID
    public let version: UInt64
    public let state: State
    public let head: Data
    /// The author's GitHub login, as its card names it (display only).
    public let login: String
    public let deviceID: TeamDeviceID
    public let date: Date
    let signature: Data

    /// A marker signed by `author`.
    public static func make(
        spaceID: SpaceID,
        version: UInt64,
        state: State,
        head: Data,
        login: String,
        author: TeamDeviceKeys,
        at date: Date
    ) throws(SpaceLogFailure) -> SpaceMarkerModel {
        let date = Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        let unsigned = SpaceMarkerModel(
            spaceID: spaceID,
            version: version,
            state: state,
            head: head,
            login: DisplayNameSanitizer.sanitize(login),
            deviceID: author.deviceID,
            date: date,
            signature: Data()
        )
        let signature: Data
        do {
            signature = try author.sign(unsigned.signedMessage)
        } catch {
            throw .badSignature
        }
        return SpaceMarkerModel(
            spaceID: spaceID,
            version: version,
            state: state,
            head: head,
            login: unsigned.login,
            deviceID: author.deviceID,
            date: date,
            signature: signature
        )
    }

    var signedMessage: Data {
        var message = Data()
        message.appendLengthPrefixed(SpaceProtocol.markerLabel)
        message.append(contentsOf: spaceID.bytes)
        message.appendBigEndian(version)
        message.append(state == .publishing ? 1 : 2)
        message.appendLengthPrefixed(head)
        message.appendLengthPrefixed(deviceID.bytes)
        message.appendLengthPrefixed(Data(Self.dateText(date).utf8))
        message.appendLengthPrefixed(Data(login.utf8))
        return message
    }

    /// True when a member of `members` signed it.
    public func isSigned(by members: [SpaceMemberModel]) -> Bool {
        guard let member = members.first(where: { $0.deviceID == deviceID }) else { return false }
        return member.isValidSignature(signature, for: signedMessage)
    }

    // MARK: - Variable value

    private struct Wire: Codable {
        let at: String
        let by: String
        let dev: String
        let f: Int
        let head: String
        let sig: String
        let space: String
        let state: State
        let v: UInt64
    }

    /// The variable's value (≤ ``SpaceProtocol/maxMarkerBytes``).
    public func encoded() -> String {
        let wire = Wire(
            at: Self.dateText(date),
            by: login,
            dev: deviceID.hex,
            f: Int(SpaceProtocol.format),
            head: head.hexEncoded,
            sig: signature.base64EncodedString(),
            space: spaceID.uuidString,
            state: state,
            v: version
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(wire) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a variable value; nil for anything malformed, oversized or of another format.
    public static func decode(_ text: String) -> SpaceMarkerModel? {
        let data = Data(text.utf8)
        guard data.count <= SpaceProtocol.maxMarkerBytes,
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              wire.f == Int(SpaceProtocol.format),
              let spaceID = SpaceID(uuidString: wire.space),
              let head = Data(hexEncoded: wire.head), head.count == SpaceProtocol.hashBytes,
              let deviceID = TeamDeviceID(hex: wire.dev),
              let signature = Data(base64Encoded: wire.sig), signature.count == TeamProtocol.signatureBytes,
              let date = try? dateStyle.parse(wire.at),
              wire.by.utf8.count <= TeamProtocol.maxCardStringBytes
        else { return nil }
        return SpaceMarkerModel(
            spaceID: spaceID,
            version: wire.v,
            state: wire.state,
            head: head,
            login: wire.by,
            deviceID: deviceID,
            date: date,
            signature: signature
        )
    }

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func dateText(_ date: Date) -> String {
        dateStyle.format(date)
    }
}

/// The pure gate (S5 steps 1–2): GitHub's marker against this Mac's verified head.
public enum SpaceGate {
    /// - Parameters:
    ///   - markerText: the `FXVAULT_SPACE` value GitHub lists, or nil when the scope has none.
    ///   - state: this Mac's verified log state.
    ///   - device: this Mac (its own unfinished claim never blocks it; a removed member is
    ///     ``SpaceGateDecision/notAMember``).
    public static func decide(
        markerText: String?,
        state: SpaceStateModel,
        device: TeamDeviceID,
        now: Date
    ) -> SpaceGateDecision {
        guard state.isMember(device) else { return .notAMember }
        guard let markerText else { return .clear }
        guard let marker = SpaceMarkerModel.decode(markerText),
              marker.spaceID == state.spaceID,
              marker.isSigned(by: state.members)
        else { return .invalidMarker }
        switch marker.state {
        case .published:
            if marker.version == state.headVersion {
                return marker.head == state.headHash ? .clear : .forked
            }
            return marker.version > state.headVersion ? .behind(version: marker.version, login: marker.login) : .ahead
        case .publishing:
            let parent = marker.version - 1
            if parent > state.headVersion {
                return .behind(version: parent, login: marker.login)
            }
            if parent < state.headVersion {
                return .ahead
            }
            guard marker.head == state.headHash else { return .forked }
            if marker.deviceID == device {
                return .clear
            }
            let age = now.timeIntervalSince(marker.date)
            return .publishing(login: marker.login, since: marker.date, isStale: age >= SpaceProtocol.claimStaleAfter.timeInterval)
        }
    }
}
