import CryptoKit
import Foundation

/// Presence pseudonyms (T3): the Bonjour instance name a Mac visible to its teammates advertises
/// on ``TeamProtocol/presenceServiceType``.
///
/// `pseudonym(window) = hex(HMAC-SHA256(announceKey, LP(label) ‖ u64be(window))[0..<16])`, with
/// `window = ⌊unix time / 900⌋`. Only a device's teammates hold its announce key, so to anyone
/// else the name is 32 random-looking hex characters that change every 15 minutes and cannot be
/// linked to the previous ones.
public enum TeamPseudonym {
    /// The 15-minute window `date` falls in.
    public static func window(at date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / Double(TeamProtocol.pseudonymWindowSeconds)).rounded(.down))
    }

    /// When the window after the one of `date` starts (the advertiser re-registers then).
    public static func nextWindowStart(after date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval((window(at: date) + 1) * TeamProtocol.pseudonymWindowSeconds))
    }

    /// The instance name for `announceKey` in `window`.
    public static func name(announceKey: Data, window: Int64) -> String {
        var message = Data()
        message.appendLengthPrefixed(TeamProtocol.pseudonymLabel)
        message.appendBigEndian(UInt64(bitPattern: window))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: announceKey))
        return Data(mac).prefix(TeamProtocol.pseudonymBytes).hexEncoded
    }

    /// This device's instance name at `date`.
    public static func name(for keys: TeamDeviceKeys, at date: Date) -> String {
        name(announceKey: keys.announceKey, window: window(at: date))
    }
}

/// Recognizes teammates among the instance names on the presence service (T3): each teammate's
/// pseudonyms for the current window and ``TeamProtocol/pseudonymWindowTolerance`` windows on
/// each side, so Mac clocks a few minutes apart still match.
public struct TeamPresenceMatcher: Sendable {
    private let names: [String: TeamDeviceID]

    /// - Parameters:
    ///   - teammates: the paired devices (their announce keys).
    ///   - date: now.
    public init(teammates: [TeamCardModel], at date: Date) {
        let current = TeamPseudonym.window(at: date)
        let tolerance = TeamProtocol.pseudonymWindowTolerance
        var names: [String: TeamDeviceID] = [:]
        for teammate in teammates {
            for window in (current - tolerance)...(current + tolerance) {
                names[TeamPseudonym.name(announceKey: teammate.announceKey, window: window)] = teammate.deviceID
            }
        }
        self.names = names
    }

    /// The teammate advertising `instanceName`, or nil (a stranger, or a name from another window).
    public func teammate(advertising instanceName: String) -> TeamDeviceID? {
        names[instanceName.lowercased()]
    }
}
