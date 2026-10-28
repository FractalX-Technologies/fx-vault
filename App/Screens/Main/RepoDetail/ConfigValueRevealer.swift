import Foundation
import Observation
import VaultCore
import VaultData

/// The values a detail table shows (§5.11), shared by repository scopes and folders (v0.7.0): a
/// secret is decrypted only while revealed and masked again after `Timeouts.revealRemask`
/// (`Timeouts.revealAllRemask` for Reveal All's, together);
/// variables are decrypted for the visible rows only. The owner masks everything on resign
/// active, on a change of scope or folder and on lock.
@Observable
final class ConfigValueRevealer {
    /// Decrypts one item; the caller wipes the bytes.
    typealias Reveal = (ConfigItemID) throws(ConfigRepositoryError) -> SecretBytes

    private(set) var revealedValues: [ConfigItemID: String] = [:]
    private(set) var variableValues: [ConfigItemID: String] = [:]
    /// When each revealed value hides again (the notes' countdown, board Place-Reveal).
    private(set) var hideDates: [ConfigItemID: Date] = [:]
    /// When the values of Reveal All hide again, together; nil when it isn't on. Its values
    /// are the revealed ones without a ``hideDates`` entry of their own.
    private(set) var allHideDate: Date?
    /// The scheduled re-mask of each revealed value (internal so tests can await it).
    @ObservationIgnored private(set) var remaskTasks: [ConfigItemID: Task<Void, Never>] = [:]
    /// The scheduled re-mask of Reveal All's values (internal so tests can await it).
    @ObservationIgnored private(set) var revealAllTask: Task<Void, Never>?
    /// Secrets just saved from the notes editor (1.0 N2), by name: their values were on screen
    /// while editing, so each shows without asking once its row arrives, then hides as any other.
    @ObservationIgnored private var savedNames: Set<String> = []
    /// After this, names still waiting no longer show: their values left the screen long ago.
    @ObservationIgnored private var savedNamesExpiry: Date?
    @ObservationIgnored private let decrypt: Reveal
    @ObservationIgnored private let clock: any VaultClock

    /// `reveal` decrypts an item of the owner's kind (organization items have their own
    /// repository, 1.0 B9).
    init(clock: any VaultClock, reveal: @escaping Reveal) {
        self.clock = clock
        decrypt = reveal
    }

    convenience init(config: ConfigRepository, clock: any VaultClock) {
        self.init(clock: clock, reveal: config.reveal)
    }

    func display(for row: ConfigRowModel) -> ConfigValueDisplayModel {
        display(id: row.id, kind: row.kind, hasValue: row.hasValue)
    }

    func display(id: ConfigItemID, kind: ConfigKind, hasValue: Bool) -> ConfigValueDisplayModel {
        guard hasValue else { return .missing }
        switch kind {
        case .secret:
            return revealedValues[id].map(ConfigValueDisplayModel.revealed) ?? .masked
        case .variable:
            return variableValues[id].map(ConfigValueDisplayModel.plain) ?? .masked
        }
    }

    func isRevealed(_ id: ConfigItemID) -> Bool {
        revealedValues[id] != nil
    }

    /// True while any value is revealed (the window is kept out of screen capture).
    var isShowingRevealedValue: Bool {
        !revealedValues.isEmpty
    }

    /// Decrypts one secret for display and schedules its re-mask.
    func reveal(_ id: ConfigItemID) throws(ConfigRepositoryError) {
        let value = try decrypt(id)
        defer { value.wipe() }
        guard let text = value.utf8String() else { throw .unexpected }
        revealedValues[id] = text
        hideDates[id] = clock.now.addingTimeInterval(Timeouts.revealRemask.timeInterval)
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

    /// Decrypts every secret of `ids` (all of them or none) and masks them together after
    /// `Timeouts.revealAllRemask`. A value revealed on its own joins the shared countdown.
    func revealAll(_ ids: [ConfigItemID]) throws(ConfigRepositoryError) {
        var texts: [ConfigItemID: String] = [:]
        for id in ids {
            let value = try decrypt(id)
            defer { value.wipe() }
            guard let text = value.utf8String() else { throw .unexpected }
            texts[id] = text
        }
        for id in ids {
            remaskTasks.removeValue(forKey: id)?.cancel()
            hideDates.removeValue(forKey: id)
        }
        revealedValues.merge(texts) { $1 }
        allHideDate = clock.now.addingTimeInterval(Timeouts.revealAllRemask.timeInterval)
        revealAllTask?.cancel()
        let clock = clock
        revealAllTask = Task { [weak self] in
            do {
                try await clock.sleep(for: Timeouts.revealAllRemask)
            } catch {
                return
            }
            self?.hideRevealAll()
        }
    }

    var isRevealingAll: Bool {
        allHideDate != nil
    }

    /// Shows the secrets named `names` as their rows arrive (``follow(liveIDs:variableIDs:secrets:)``).
    func revealOnArrival(_ names: Set<String>) {
        savedNames = names
        savedNamesExpiry = clock.now.addingTimeInterval(Timeouts.revealRemask.timeInterval)
    }

    func hide(_ id: ConfigItemID) {
        remaskTasks.removeValue(forKey: id)?.cancel()
        revealedValues.removeValue(forKey: id)
        hideDates.removeValue(forKey: id)
        // The last of Reveal All's values hidden on its own ends Reveal All.
        if isRevealingAll, revealedValues.keys.allSatisfy({ hideDates[$0] != nil }) {
            endRevealAll()
        }
    }

    /// Masks every revealed value.
    func remaskAll() {
        for task in remaskTasks.values {
            task.cancel()
        }
        remaskTasks.removeAll()
        savedNames.removeAll()
        revealedValues.removeAll()
        hideDates.removeAll()
        endRevealAll()
    }

    /// Masks Reveal All's values; one revealed on its own since keeps its countdown.
    private func hideRevealAll() {
        for id in revealedValues.keys where hideDates[id] == nil {
            revealedValues.removeValue(forKey: id)
        }
        endRevealAll()
    }

    private func endRevealAll() {
        revealAllTask?.cancel()
        revealAllTask = nil
        allHideDate = nil
    }

    /// Masks the revealed values of rows that are gone, shows the secrets of `secrets` (id to name)
    /// saved from the notes editor, and decrypts the variables of `ids` for plaintext display (a
    /// locked vault leaves them masked).
    func follow(liveIDs: Set<ConfigItemID>, variableIDs: [ConfigItemID], secrets: [ConfigItemID: String]) {
        for id in revealedValues.keys where !liveIDs.contains(id) {
            hide(id)
        }
        if let savedNamesExpiry, clock.now > savedNamesExpiry {
            savedNames.removeAll()
        }
        let arrived = secrets.filter { savedNames.contains($0.value) }
        if !arrived.isEmpty {
            // The save is one transaction: its snapshot brings every name at once. A name left
            // over must not show a secret that arrives later some other way (a pull, a drop).
            savedNames.removeAll()
        }
        for id in arrived.keys {
            do {
                try reveal(id)
            } catch {
                AppLog.ui.error("A saved secret could not be shown")
            }
        }
        var values: [ConfigItemID: String] = [:]
        for id in variableIDs {
            do {
                let value = try decrypt(id)
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

/// An item a place's snapshot holds: a scope's, a folder's or a Key Vault's.
protocol ConfigNamedItem {
    var id: ConfigItemID { get }
    var kind: ConfigKind { get }
    var name: String { get }
    var isDeleted: Bool { get }
}

extension ConfigItemModel: ConfigNamedItem {}
extension DestinationItemModel: ConfigNamedItem {}

extension FolderItemModel: ConfigNamedItem {
    // A folder's item is removed at once: it has no pending deletion.
    var isDeleted: Bool {
        false
    }
}

extension Sequence where Element: ConfigNamedItem {
    /// The live secrets' names by id, for ``ConfigValueRevealer/follow(liveIDs:variableIDs:secrets:)``:
    /// a pending deletion may share a new secret's name.
    var secretNames: [ConfigItemID: String] {
        Dictionary(uniqueKeysWithValues: filter { $0.kind == .secret && !$0.isDeleted }.map { ($0.id, $0.name) })
    }
}
