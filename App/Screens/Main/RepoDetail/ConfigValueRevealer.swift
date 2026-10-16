import Foundation
import Observation
import VaultCore
import VaultData

/// The values a detail table shows (§5.11), shared by repository scopes and folders (v0.7.0): a
/// secret is decrypted only while revealed and masked again after `Timeouts.revealRemask`;
/// variables are decrypted for the visible rows only. The owner masks everything on resign
/// active, on a change of scope or folder and on lock.
@Observable
final class ConfigValueRevealer {
    private(set) var revealedValues: [ConfigItemID: String] = [:]
    private(set) var variableValues: [ConfigItemID: String] = [:]
    /// The scheduled re-mask of each revealed value (internal so tests can await it).
    @ObservationIgnored private(set) var remaskTasks: [ConfigItemID: Task<Void, Never>] = [:]
    @ObservationIgnored private let config: ConfigRepository
    @ObservationIgnored private let clock: any VaultClock

    init(config: ConfigRepository, clock: any VaultClock) {
        self.config = config
        self.clock = clock
    }

    func display(for row: ConfigRowModel) -> ConfigValueDisplayModel {
        guard row.hasValue else { return .missing }
        switch row.kind {
        case .secret:
            return revealedValues[row.id].map(ConfigValueDisplayModel.revealed) ?? .masked
        case .variable:
            return variableValues[row.id].map(ConfigValueDisplayModel.plain) ?? .masked
        }
    }

    func isRevealed(_ id: ConfigItemID) -> Bool {
        revealedValues[id] != nil
    }

    /// Decrypts one secret for display and schedules its re-mask.
    func reveal(_ id: ConfigItemID) throws(ConfigRepositoryError) {
        let value = try config.reveal(id)
        defer { value.wipe() }
        guard let text = value.utf8String() else { throw .unexpected }
        revealedValues[id] = text
        remaskTasks[id]?.cancel()
        let clock = clock
        remaskTasks[id] = Task { [weak self] in
            do {
                try await clock.sleep(for: Timeouts.revealRemask)
            } catch {
                return
            }
            self?.hide(id)
        }
    }

    func hide(_ id: ConfigItemID) {
        remaskTasks.removeValue(forKey: id)?.cancel()
        revealedValues.removeValue(forKey: id)
    }

    /// Masks every revealed value.
    func remaskAll() {
        for task in remaskTasks.values {
            task.cancel()
        }
        remaskTasks.removeAll()
        revealedValues.removeAll()
    }

    /// Masks the revealed values of rows that are gone and decrypts the variables of `ids` for
    /// plaintext display (a locked vault leaves them masked).
    func follow(liveIDs: Set<ConfigItemID>, variableIDs: [ConfigItemID]) {
        for id in revealedValues.keys where !liveIDs.contains(id) {
            hide(id)
        }
        var values: [ConfigItemID: String] = [:]
        for id in variableIDs {
            do {
                let value = try config.reveal(id)
                values[id] = value.utf8String()
                value.wipe()
            } catch {
                continue
            }
        }
        variableValues = values
    }

    /// Drops the decrypted variables (lock, another scope or folder).
    func clearVariables() {
        variableValues.removeAll()
    }
}
