import Foundation
import os
import SharingKit
import VaultCore
import VaultCrypto
import VaultStore

/// Why a ``TeamRepository`` call failed. Carries no names, keys or text.
public enum TeamRepositoryError: Error, Sendable, Hashable {
    /// The vault is locked (teammate keys live in it).
    case vault(VaultError)
    case store(StoreError)
    /// Stored keys or a stored card no longer match (``ShareError/teamKeysInvalid``,
    /// ``ShareError/teamCardInvalid``).
    case keys(ShareError)
    /// No teammate with that id.
    case teammateNotFound
    case unexpected

    static func wrap(_ error: any Error) -> TeamRepositoryError {
        switch error {
        case let error as TeamRepositoryError: error
        case let error as VaultError: .vault(error)
        case let error as StoreError: .store(error)
        case let error as ShareError: .keys(error)
        case is CryptoError: .vault(.corrupted(.fieldDecryptionFailed))
        default: .unexpected
        }
    }
}

/// Teammates (v0.5.0, tasks/todo.md T1–T2, T6): this device's keys and the paired devices.
///
/// - This device's keys (Ed25519, X25519, announce key) are created on first use and stored
///   sealed in the vault (`device_identity.secret_ct`); they are read only while it is unlocked.
/// - A teammate's public keys are plaintext; its announce key is sealed (it recognizes that
///   teammate's pseudonyms). Names are what its Mac sent, sanitized.
/// - Removing a teammate gives this device a new announce key, so the removed device no longer
///   recognizes it; the remaining teammates get the new card the next time they are nearby
///   (`needs_card_update`, ``cardUpdateDelivered(to:)``).
/// - A teammate paired remotely as the inviter (v0.9.0) is stored before its announce key is
///   known (``addTeammateAwaitingAnnounceKey(deviceID:signingPublicKey:agreementPublicKey:login:displayName:macName:)``).
///   Its card then carries a random announce key that is never stored, so presence matches none
///   of its pseudonyms while sessions it starts still verify; the real key arrives in a
///   teammates file (``fillAnnounceKeyIfMissing(_:teammate:)``) or a nearby card update.
public struct TeamRepository: Sendable {
    public let session: VaultSession
    let clock: any VaultClock

    public init(session: VaultSession, clock: any VaultClock = SystemClock()) {
        self.session = session
        self.clock = clock
    }

    private var store: TeamStore {
        TeamStore(database: session.database)
    }

    // MARK: - This device

    /// This device's teammate keys, created on first use.
    public func deviceKeys() throws(TeamRepositoryError) -> TeamDeviceKeys {
        let now = clock.now
        return try perform {
            try session.write { keys, tx in
                if let record = try store.fetchIdentity(in: tx) {
                    return try Self.open(record, keys: keys)
                }
                let generated = TeamDeviceKeys.generate()
                try store.saveIdentity(try Self.seal(generated, keys: keys, now: now, createdAt: now), in: tx)
                Self.log.info("Created this device's teammate keys")
                return generated
            }
        }
    }

    // MARK: - Teammates

    /// Teammates without keys, now and after each change (works while locked).
    public func observeTeammates() -> AsyncThrowingStream<[TeammateModel], any Error> {
        store.observeTeammates()
    }

    /// Teammates without keys, read now.
    public func teammates() throws(TeamRepositoryError) -> [TeammateModel] {
        try perform { try store.fetchTeammateModels() }
    }

    /// Every teammate's card (announce keys opened), for presence and sessions. A teammate whose
    /// announce key has not arrived gets a fresh random one here (never stored), so no pseudonym
    /// matches it.
    public func teammateCards() throws(TeamRepositoryError) -> [TeamCardModel] {
        try perform {
            try session.read { keys, tx in
                try store.fetchTeammates(in: tx).map { try Self.card(of: $0, keys: keys) }
            }
        }
    }

    /// Stores a device paired with Add Teammate; pairing the same device again replaces it.
    ///
    /// - Parameter pairedVia: `.remote` for the inviter of a remote pairing (v0.9.0), which
    ///   received the teammate's announce key in the reply; the teammate then still needs this
    ///   device's card, so `needs_card_update` is set.
    public func addTeammate(_ card: TeamCardModel, pairedVia: TeammatePairing = .nearby) throws(TeamRepositoryError) {
        let now = clock.now
        try perform {
            try session.write { keys, tx in
                let existing = try store.fetchTeammate(deviceID: card.deviceID.hex, in: tx)
                var record = try Self.record(for: card, keys: keys, pairedAt: now, existing: existing)
                record.pairedVia = pairedVia
                if pairedVia == .remote {
                    record.needsCardUpdate = true
                }
                try store.saveTeammate(record, in: tx)
            }
        }
        Self.log.info("Added a teammate")
    }

    /// Stores the inviter of a remote pairing (v0.9.0) without its announce key, which only
    /// arrives later. The keys are checked as a card's are (the device id must derive from
    /// them). Pairing the same device again keeps a known announce key.
    public func addTeammateAwaitingAnnounceKey(
        deviceID: TeamDeviceID,
        signingPublicKey: Data,
        agreementPublicKey: Data,
        login: String,
        displayName: String,
        macName: String
    ) throws(TeamRepositoryError) {
        let now = clock.now
        try perform {
            // Validates the keys and names exactly as a received card; the placeholder announce
            // key is discarded.
            let checked = try TeamCardModel(
                deviceID: deviceID,
                signingPublicKey: signingPublicKey,
                agreementPublicKey: agreementPublicKey,
                announceKey: Self.placeholderAnnounceKey(),
                login: login,
                displayName: displayName,
                macName: macName
            )
            try session.write { _, tx in
                let existing = try store.fetchTeammate(deviceID: deviceID.hex, in: tx)
                let keepsAnnounce = existing.map {
                    $0.signingPublicKey == signingPublicKey && $0.agreementPublicKey == agreementPublicKey
                } ?? false
                try store.saveTeammate(
                    TeammateRecord(
                        deviceID: deviceID.hex,
                        signingPublicKey: checked.signingPublicKey,
                        agreementPublicKey: checked.agreementPublicKey,
                        announceCiphertext: keepsAnnounce ? existing?.announceCiphertext : nil,
                        login: checked.login,
                        displayName: checked.displayName,
                        macName: checked.macName,
                        pairedAt: now,
                        lastSeenAt: existing?.lastSeenAt,
                        isMuted: existing?.isMuted ?? false,
                        needsCardUpdate: existing?.needsCardUpdate ?? false,
                        pairedVia: .remote
                    ),
                    in: tx
                )
            }
        }
        Self.log.info("Added a teammate paired remotely")
    }

    /// Stores a teammate's announce key from a verified teammates file (v0.9.0) when this Mac
    /// has none for it yet. Returns true when it stored the key; a known key is never replaced
    /// here (an older file must not roll back a newer card update).
    @discardableResult
    public func fillAnnounceKeyIfMissing(_ announceKey: Data, teammate id: String) throws(TeamRepositoryError) -> Bool {
        guard announceKey.count == TeamProtocol.announceKeyBytes else {
            throw TeamRepositoryError.keys(.teamCardInvalid)
        }
        return try perform {
            try session.write { keys, tx in
                guard var record = try store.fetchTeammate(deviceID: id, in: tx),
                      let deviceID = TeamDeviceID(hex: record.deviceID)
                else { throw TeamRepositoryError.teammateNotFound }
                guard record.announceCiphertext == nil else { return false }
                var copy = announceKey
                let secret = SecretBytes(wipingSource: &copy)
                defer { secret.wipe() }
                record.announceCiphertext = try keys.seal(secret, for: Self.announceAAD(deviceID: deviceID))
                try store.saveTeammate(record, in: tx)
                return true
            }
        }
    }

    /// A teammate's new card from a CARD_UPDATE (same keys, new announce key).
    public func applyCardUpdate(_ card: TeamCardModel) throws(TeamRepositoryError) {
        try perform {
            try session.write { keys, tx in
                guard let existing = try store.fetchTeammate(deviceID: card.deviceID.hex, in: tx),
                      existing.signingPublicKey == card.signingPublicKey,
                      existing.agreementPublicKey == card.agreementPublicKey
                else { throw TeamRepositoryError.teammateNotFound }
                var record = try Self.record(for: card, keys: keys, pairedAt: existing.pairedAt, existing: existing)
                record.pairedVia = existing.pairedVia
                try store.saveTeammate(record, in: tx)
            }
        }
    }

    /// Removes a teammate and gives this device a new announce key; every remaining teammate
    /// needs the new card.
    public func removeTeammate(id: String) throws(TeamRepositoryError) {
        let now = clock.now
        try perform {
            try session.write { keys, tx in
                guard try store.deleteTeammate(deviceID: id, in: tx) else {
                    throw TeamRepositoryError.teammateNotFound
                }
                guard let record = try store.fetchIdentity(in: tx) else { return }
                let renewed = try Self.open(record, keys: keys).withNewAnnounceKey()
                try store.saveIdentity(try Self.seal(renewed, keys: keys, now: now, createdAt: record.createdAt), in: tx)
                try store.markAllNeedCardUpdate(in: tx)
            }
        }
        Self.log.info("Removed a teammate and renewed this device's announce key")
    }

    public func setMuted(_ isMuted: Bool, teammate id: String) throws(TeamRepositoryError) {
        try update(id) { $0.isMuted = isMuted }
    }

    /// Records that `id` was seen nearby now.
    public func markSeen(_ id: String) throws(TeamRepositoryError) {
        let now = clock.now
        try update(id) { $0.lastSeenAt = now }
    }

    /// The teammate stored this device's current card.
    public func cardUpdateDelivered(to id: String) throws(TeamRepositoryError) {
        try update(id) { $0.needsCardUpdate = false }
    }

    // MARK: - Private

    private static let log = Logger(subsystem: "io.fractalx.fxvault", category: "team")

    private func update(_ id: String, _ change: @escaping (inout TeammateRecord) -> Void) throws(TeamRepositoryError) {
        try perform {
            try session.database.write { tx in
                try store.updateTeammate(deviceID: id, in: tx, change)
            }
        }
    }

    private func perform<Result>(_ body: () throws -> Result) throws(TeamRepositoryError) -> Result {
        do {
            return try body()
        } catch {
            throw TeamRepositoryError.wrap(error)
        }
    }

    static func identityAAD(deviceID: TeamDeviceID) -> SecretFieldAAD {
        SecretFieldAAD(table: DeviceIdentityRecord.databaseTableName, column: "secret_ct", rowKey: deviceID.bytes)
    }

    static func announceAAD(deviceID: TeamDeviceID) -> SecretFieldAAD {
        SecretFieldAAD(table: TeammateRecord.databaseTableName, column: "announce_ct", rowKey: deviceID.bytes)
    }

    private static func seal(
        _ device: TeamDeviceKeys,
        keys: borrowing UnlockedKeys,
        now: Date,
        createdAt: Date
    ) throws -> DeviceIdentityRecord {
        let secret = device.secretBytes()
        defer { secret.wipe() }
        return DeviceIdentityRecord(
            deviceID: device.deviceID.hex,
            secretCiphertext: try keys.seal(secret, for: identityAAD(deviceID: device.deviceID)),
            createdAt: createdAt,
            updatedAt: now
        )
    }

    private static func open(_ record: DeviceIdentityRecord, keys: borrowing UnlockedKeys) throws -> TeamDeviceKeys {
        guard let deviceID = TeamDeviceID(hex: record.deviceID) else { throw ShareError.teamKeysInvalid }
        let secret = try keys.open(record.secretCiphertext, for: identityAAD(deviceID: deviceID))
        defer { secret.wipe() }
        let device = try TeamDeviceKeys(secretBytes: secret)
        guard device.deviceID == deviceID else { throw ShareError.teamKeysInvalid }
        return device
    }

    private static func record(
        for card: TeamCardModel,
        keys: borrowing UnlockedKeys,
        pairedAt: Date,
        existing: TeammateRecord?
    ) throws -> TeammateRecord {
        var announce = card.announceKey
        let secret = SecretBytes(wipingSource: &announce)
        defer { secret.wipe() }
        return TeammateRecord(
            deviceID: card.deviceID.hex,
            signingPublicKey: card.signingPublicKey,
            agreementPublicKey: card.agreementPublicKey,
            announceCiphertext: try keys.seal(secret, for: announceAAD(deviceID: card.deviceID)),
            login: card.login,
            displayName: card.displayName,
            macName: card.macName,
            pairedAt: pairedAt,
            lastSeenAt: existing?.lastSeenAt,
            isMuted: existing?.isMuted ?? false,
            needsCardUpdate: existing?.needsCardUpdate ?? false
        )
    }

    static func card(of record: TeammateRecord, keys: borrowing UnlockedKeys) throws -> TeamCardModel {
        guard let deviceID = TeamDeviceID(hex: record.deviceID) else { throw ShareError.teamCardInvalid }
        let announceKey: Data
        if let ciphertext = record.announceCiphertext {
            let announce = try keys.open(ciphertext, for: announceAAD(deviceID: deviceID))
            defer { announce.wipe() }
            announceKey = announce.withUnsafeBytes { Data($0) }
        } else {
            announceKey = placeholderAnnounceKey()
        }
        return try TeamCardModel(
            deviceID: deviceID,
            signingPublicKey: record.signingPublicKey,
            agreementPublicKey: record.agreementPublicKey,
            announceKey: announceKey,
            login: record.login,
            displayName: record.displayName,
            macName: record.macName
        )
    }

    /// A fresh random announce key for a teammate whose key is unknown: no pseudonym derived
    /// from it matches a real device. Never stored.
    private static func placeholderAnnounceKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<TeamProtocol.announceKeyBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
