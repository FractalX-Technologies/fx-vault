import SyncEngine
import VaultCore
import VaultStore

/// Maps VaultStore's ciphertext-free projections to SyncEngine's input models (§7.1, §7.7).
///
/// SyncEngine does not depend on VaultStore, so every VaultData component that derives changes,
/// plans edits or detects drift goes through this mapper: one place keeps the field-by-field
/// mapping correct.
public enum RepoSnapshotMapper {
    /// One `config_items` row as a snapshot (fingerprints and flags only).
    public static func item(_ state: ConfigItemState) -> ConfigItemSnapshotModel {
        ConfigItemSnapshotModel(
            id: state.id,
            scope: state.scope,
            kind: state.kind,
            name: state.name,
            valueFingerprint: state.valueFingerprint,
            isDeleted: state.isDeleted,
            syncedName: state.syncedName,
            hasSyncedValue: state.hasSyncedValue,
            syncedFingerprint: state.syncedFingerprint,
            forcePush: state.forcePush,
            forcePushRequestedAt: state.forcePushRequestedAt,
            remoteUpdatedAt: state.remoteUpdatedAt,
            verifyState: state.verifyState,
            preWriteUpdatedAt: state.preWriteUpdatedAt,
            provenance: state.provenance
        )
    }

    /// One repository's pending-change inputs as a snapshot.
    public static func snapshot(_ inputs: RepoPendingInputsModel) -> RepoSnapshotModel {
        RepoSnapshotModel(
            repository: inputs.repository,
            environments: inputs.environments,
            items: inputs.items.map(item)
        )
    }
}
