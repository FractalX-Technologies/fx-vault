import Foundation
import SharingKit
import VaultCore
import VaultStore

/// Space sync with a teammate outside the local network (v0.6.0, Q4). Off by default; each Mac
/// turns it on for each teammate. Works while locked (no secrets).
public struct TeammateRemoteAccessModel: Sendable, Hashable, Identifiable {
    public let deviceID: String
    /// This Mac accepts the teammate's space sync over the network and syncs with it there.
    public let isAllowed: Bool
    /// Where the teammate's Mac listens; nil when this Mac only accepts its connections.
    public let address: TeamRemoteAddressModel?
    public let lastConnectedAt: Date?

    public var id: String {
        deviceID
    }

    init(record: TeammateAddressRecord) {
        deviceID = record.deviceID
        isAllowed = record.allowsRemote
        if let host = record.host, let port = record.port.flatMap(UInt16.init(exactly:)) {
            address = TeamRemoteAddressModel(host: host, port: port)
        } else {
            address = nil
        }
        lastConnectedAt = record.lastConnectedAt
    }
}

extension TeamRepository {
    private var spaceStore: SpaceStore {
        SpaceStore(database: session.database)
    }

    /// Every teammate's remote access, read now.
    public func remoteAccess() throws(TeamRepositoryError) -> [TeammateRemoteAccessModel] {
        do {
            return try spaceStore.fetchAddresses().map(TeammateRemoteAccessModel.init)
        } catch {
            throw .wrap(error)
        }
    }

    /// ``remoteAccess()`` now and after each change.
    public func observeRemoteAccess() -> AsyncThrowingStream<[TeammateRemoteAccessModel], any Error> {
        ObservationMapper.map(spaceStore.observeAddresses()) { $0.map(TeammateRemoteAccessModel.init) }
    }

    /// Turns remote space sync with teammate `id` on or off, with its address (nil: accept only).
    public func setRemoteAccess(_ id: String, isAllowed: Bool, address: TeamRemoteAddressModel?) throws(TeamRepositoryError) {
        do {
            try session.database.write { tx in
                guard try TeamStore(database: session.database).fetchTeammate(deviceID: id, in: tx) != nil else {
                    throw TeamRepositoryError.teammateNotFound
                }
                let existing = try spaceStore.fetchAddresses(in: tx).first { $0.deviceID == id }
                try spaceStore.saveAddress(
                    TeammateAddressRecord(
                        deviceID: id,
                        host: address?.host,
                        port: address.map { Int64($0.port) },
                        allowsRemote: isAllowed,
                        lastConnectedAt: existing?.lastConnectedAt
                    ),
                    in: tx
                )
            }
        } catch {
            throw .wrap(error)
        }
    }

    /// Records a remote space session with teammate `id` (shown in Members and Preferences).
    public func markRemoteConnection(_ id: String, at date: Date) throws(TeamRepositoryError) {
        do {
            try session.database.write { tx in
                guard var record = try spaceStore.fetchAddresses(in: tx).first(where: { $0.deviceID == id }) else { return }
                record.lastConnectedAt = date
                try spaceStore.saveAddress(record, in: tx)
            }
        } catch {
            throw .wrap(error)
        }
    }
}
