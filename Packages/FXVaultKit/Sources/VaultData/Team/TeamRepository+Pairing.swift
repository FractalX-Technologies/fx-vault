import Foundation
import SharingKit
import VaultCore

/// An invitation read on the invited Mac (remote pairing step 1, v0.9.0): who sent it and
/// whether that device is already a teammate. Nothing is stored yet.
public struct RemoteInvitationReadModel: Sendable, Hashable {
    /// Pass it to ``TeamRepository/makeReply(to:as:)``.
    public let invitation: RemoteInvitationModel
    /// The inviter's device when it is already a teammate here (pairing again updates it).
    public let existingTeammate: TeammateModel?

    public var inviter: TeamPublicCardModel {
        invitation.inviter
    }
}

/// A reply read on the inviting Mac (remote pairing step 3, v0.9.0): the new teammate, the code
/// to compare and whether that device is already a teammate. Nothing is stored yet.
public struct RemoteReplyReadModel: Sendable, Hashable {
    /// Pass `reply.teammate` to ``TeamRepository/confirmReplier(_:)`` once the codes match.
    public let reply: RemotePairingReplyModel
    public let existingTeammate: TeammateModel?

    public var teammate: TeamCardModel {
        reply.teammate
    }

    public var code: RemotePairingCodeModel {
        reply.code
    }
}

/// What confirming a remote pairing did.
public enum RemotePairingOutcome: Sendable, Hashable {
    /// A new teammate.
    case added
    /// The device was already a teammate: its names and keys were refreshed, never duplicated.
    case updated
}

/// Remote pairing (v0.9.0, P4) over SharingKit's ``RemotePairing``: Add Teammate › Not Nearby….
///
/// 1. A: ``makeInvitation(as:)`` → send the `.fxvcard` to B.
/// 2. B: ``readInvitation(_:)``, ``makeReply(to:as:)`` → send the reply to A; B sees the code.
/// 3. A: ``readReply(_:)`` → A sees the code.
/// 4. Each person compares the code on a call; B confirms with ``confirmInviter(_:)``, A with
///    ``confirmReplier(_:)``.
///
/// Confirming is the only step that writes a teammate. Reading or making a file only needs this
/// device's keys (created on first use, as Add Teammate does). Failures arrive as
/// ``TeamRepositoryError/keys(_:)`` with ``ShareError/invalidPairingCard``,
/// ``ShareError/pairingExpired`` or ``ShareError/pairingOwnCard``.
///
/// B stores A without an announce key. It arrives in A's first teammates file
/// (``fillAnnounceKeyIfMissing(_:teammate:)``) or the first time the Macs meet nearby: A's
/// confirmation sets `needs_card_update`, so A sends its card in a CARD_UPDATE
/// (``applyCardUpdate(_:)``).
extension TeamRepository {
    /// What an opened `.fxvcard` is, from its header only.
    public static func pairingFileKind(of file: Data) throws(TeamRepositoryError) -> RemotePairingFileKind {
        do {
            return try RemotePairing.kind(of: file)
        } catch {
            throw .keys(error)
        }
    }

    /// Step 1 (A): a new invitation carrying this device's public keys and `identity`'s names.
    public func makeInvitation(as identity: SpaceLocalIdentityModel) throws(TeamRepositoryError) -> Data {
        let keys = try deviceKeys()
        let now = clock.now
        return try pairing { pairing throws(ShareError) in
            try pairing.makeInvitation(
                keys: keys,
                login: identity.login,
                displayName: identity.displayName,
                macName: identity.macName,
                now: now
            )
        }
    }

    /// Step 2a (B): reads an invitation. Refuses this Mac's own card and an expired invitation.
    public func readInvitation(_ file: Data) throws(TeamRepositoryError) -> RemoteInvitationReadModel {
        let keys = try deviceKeys()
        let now = clock.now
        let invitation = try pairing { pairing throws(ShareError) in
            try pairing.readInvitation(file, now: now, ownDevice: keys.deviceID)
        }
        return RemoteInvitationReadModel(
            invitation: invitation,
            existingTeammate: try teammate(withID: invitation.inviter.deviceID)
        )
    }

    /// Step 2b (B): the reply to send back and the code to compare. Stores nothing.
    public func makeReply(
        to invitation: RemoteInvitationModel,
        as identity: SpaceLocalIdentityModel
    ) throws(TeamRepositoryError) -> RemotePairingReplyFileModel {
        let keys = try deviceKeys()
        let now = clock.now
        return try pairing { pairing throws(ShareError) in
            try pairing.makeReply(
                to: invitation,
                keys: keys,
                login: identity.login,
                displayName: identity.displayName,
                macName: identity.macName,
                now: now
            )
        }
    }

    /// Step 4 (B), after the codes matched: stores the inviter, without its announce key.
    @discardableResult
    public func confirmInviter(_ inviter: TeamPublicCardModel) throws(TeamRepositoryError) -> RemotePairingOutcome {
        let keys = try deviceKeys()
        guard inviter.deviceID != keys.deviceID else { throw .keys(.pairingOwnCard) }
        let existing = try teammate(withID: inviter.deviceID)
        try addTeammateAwaitingAnnounceKey(
            deviceID: inviter.deviceID,
            signingPublicKey: inviter.signingPublicKey,
            agreementPublicKey: inviter.agreementPublicKey,
            login: inviter.login,
            displayName: inviter.displayName,
            macName: inviter.macName
        )
        return existing == nil ? .added : .updated
    }

    /// Step 3 (A): reads the reply to one of this Mac's invitations. Stores nothing.
    public func readReply(_ file: Data) throws(TeamRepositoryError) -> RemoteReplyReadModel {
        let keys = try deviceKeys()
        let now = clock.now
        let reply = try pairing { pairing throws(ShareError) in
            try pairing.readReply(file, keys: keys, now: now)
        }
        guard reply.teammate.deviceID != keys.deviceID else { throw .keys(.pairingOwnCard) }
        return RemoteReplyReadModel(reply: reply, existingTeammate: try teammate(withID: reply.teammate.deviceID))
    }

    /// Step 4 (A), after the codes matched: stores the replier with the announce key its reply
    /// sealed for this Mac, and marks that it still needs this Mac's card.
    @discardableResult
    public func confirmReplier(_ teammate: TeamCardModel) throws(TeamRepositoryError) -> RemotePairingOutcome {
        let keys = try deviceKeys()
        guard teammate.deviceID != keys.deviceID else { throw .keys(.pairingOwnCard) }
        let existing = try self.teammate(withID: teammate.deviceID)
        try addTeammate(teammate, pairedVia: .remote)
        return existing == nil ? .added : .updated
    }

    // MARK: - Private

    private func teammate(withID deviceID: TeamDeviceID) throws(TeamRepositoryError) -> TeammateModel? {
        try teammates().first { $0.id == deviceID.hex }
    }

    private func pairing<Result>(
        _ body: (RemotePairing) throws(ShareError) -> Result
    ) throws(TeamRepositoryError) -> Result {
        do {
            return try body(try RemotePairing.bundled())
        } catch {
            throw .keys(error)
        }
    }
}
