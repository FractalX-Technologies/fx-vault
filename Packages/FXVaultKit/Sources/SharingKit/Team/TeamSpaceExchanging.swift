import Foundation
import VaultCore

/// The vault side of a spaces session (v0.6.0, S6): what this Mac offers a teammate and what it
/// keeps from one. The app implements it over VaultData's `SpaceRepository`.
public protocol TeamSpaceExchanging: Sendable {
    /// This Mac's heads of every space `peer` is a member of.
    func heads(sharedWith peer: TeamDeviceID) async -> [SpaceHeadModel]
    /// Version `number` of `spaceID` in wire form for `peer`; nil when `peer` is not a member or
    /// this Mac does not have it.
    func version(_ number: UInt64, of spaceID: SpaceID, for peer: TeamDeviceID) async -> Data?
    /// Verifies and stores versions `peer` sent, in order (for a space this Mac does not have,
    /// its whole log). False stops fetching that space in this session.
    func receive(_ versions: [Data], spaceID: SpaceID, from peer: TeamDeviceID) async -> Bool
}
